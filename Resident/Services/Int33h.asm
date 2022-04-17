;---------------------Storage Interrupt Int 33h------------------
;Input : dl = Drive number, rbx = Address of buffer, 
;        al = number of sectors, ch = Track number, 
;        cl = Sector number, dh = Head number
;Input LBA: dl = Drive Number, rbx = Address of Buffer, 
;           al = number of sectors, rcx = LBA number
;
;All registers not mentioned above, preserved
;----------------------------------------------------------------
disk_io:
    cld ;Ensure all string reads/writes are in the right way
    test dl, 80h
    jnz .baddev    ;If bit 7 set, exit (temp for v0.9)
    push rdx
    inc dl          ;Inc device number count to absolute value
    cmp dl, byte [i33Devices]
    pop rdx
    ja .baddev
    cmp ah, 16h
    jz .deviceChanged   ;Pick it off

    call .busScan   ;Bus scan only in valid cases
    cmp byte [msdStatus], 40h   ;Media seek failed
    je .noDevInDrive

    test ah, ah
    jz .reset           ;ah = 00h Reset Device
    dec ah
    jz .statusreport    ;ah = 01h Get status of last op and req. sense if ok 

    mov byte [msdStatus], 00    ;Reset status byte for following operations

    dec ah
    jz .readsectors     ;ah = 02h CHS Read Sectors
    dec ah
    jz .writesectors    ;ah = 03h CHS Write Sectors
    dec ah
    jz .verify          ;ah = 04h CHS Verify Sectors
    dec ah
    jz .format          ;ah = 05h CHS Format Track (Select Head and Cylinder)

    cmp ah, 02h
    je .formatLowLevel  ;ah = 07h (SCSI) Low Level Format Device

    cmp ah, 7Dh         ;ah = 82h LBA Read Sectors
    je .lbaread
    cmp ah, 7Eh         ;ah = 83h LBA Write Sectors
    je .lbawrite
    cmp ah, 7Fh         ;ah = 84h LBA Verify Sectors
    je .lbaverify
    cmp ah, 80h         ;ah = 85h LBA Format Sectors
    je .lbaformat
    cmp ah, 83h         ;ah = 88h LBA Read Drive Parameters
    je .lbareadparams
.baddev:
    mov ah, 01h
    mov byte [msdStatus], ah   ;Invalid function requested signature
.bad:
    or byte [rsp + 2*8h], 1    ;Set Carry flag on for invalid function
    iretq
.noDevInDrive:
    mov ah, byte [msdStatus]
    or byte [rsp + 2*8h], 1    ;Set Carry flag on for invalid function
    iretq
.reset: ;Device Reset
    push rsi
    push rdx
    call .i33ehciGetDevicePtr
    call USB.ehciAdjustAsyncSchedCtrlr
    call USB.ehciMsdBOTResetRecovery
.rrexit:
    pop rdx
    pop rsi
    jc .rrbad
    mov ah, byte [msdStatus]
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.rrbad:
    mov ah, 5   ;Reset failed
    mov byte [msdStatus], ah
    or byte [rsp + 2*8h], 1    ;Set Carry flag on for invalid function
    iretq
.statusreport:  
;If NOT a host/bus/ctrlr type error, request sense and ret code
    mov ah, byte [msdStatus]    ;Get last status into ah
    test ah, ah ;If status is zero, exit
    jnz .srmain
    and byte [rsp + 2*8h], 0FEh     ;Clear CF
    iretq
.srmain:
    mov byte [msdStatus], 00    ;Reset status byte
    cmp ah, 20h     ;General Controller failure?
    je .srexit
    cmp ah, 80h     ;Timeout?
    je .srexit
;Issue a Request sense command
    push rsi
    push rax    ;Save original error code in ah on stack
    call .i33ehciGetDevicePtr
    call USB.ehciAdjustAsyncSchedCtrlr
    jc .srexitbad1
    call USB.ehciMsdBOTRequestSense
    call USB.ehciMsdBOTCheckTransaction
    test ax, ax
    pop rax         ;Get back original error code
    jnz .srexitbad2
    movzx r8, byte [ehciDataIn + 13]  ;Get ASCQ into r8
    shl r8, 8                        ;Make space in lower byte of r8 for ASC key
    mov r8b, byte [ehciDataIn + 12]   ;Get ASC into r8
    shl r8, 8                    ;Make space in lower byte of r8 for sense key
    mov r8b, byte [ehciDataIn + 2]  ;Get sense key into al
    or r8b, 0F0h                    ;Set sense signature (set upper nybble F)
    pop rsi
.srexit:
    or byte [rsp + 2*8h], 1 ;Non-zero error, requires CF=CY
    iretq
.srexitbad2:
    mov ah, -1  ;Sense operation failed
    jmp short .srexitbad
.srexitbad1:
    mov ah, 20h ;General Controller Failure
.srexitbad:
    pop rsi
    mov byte [msdStatus], ah
    jmp short .rsbad

.readsectors:
    push rdi
    mov rdi, USB.ehciMsdBOTInSector512
    call .sectorsEHCI
    pop rdi
    mov ah, byte [msdStatus]    ;Return Error code in ah
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.rsbad:
    or byte [rsp + 2*8h], 1    ;Set Carry flag on for invalid function
    iretq

.writesectors:
    push rdi
    mov rdi, USB.ehciMsdBOTOutSector512
    call .sectorsEHCI
    pop rdi
    mov ah, byte [msdStatus]
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq

.verify:
    push rdi
    mov rdi, USB.ehciMsdBOTVerify
    call .sectorsEHCI   ;Verify sector by sector
    pop rdi
    mov ah, byte [msdStatus]
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.format:
;Cleans sectors on chosen track. DOES NOT Low Level Format.
;Fills sectors with fill byte from table
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push rbp

    push rcx                    ;Save ch = Cylinder number
    mov rsi, qword [diskDptPtr]
    mov eax, 80h                 ;128 bytes
    mov cl, byte [rsi + 3]  ;Bytes per track
    shl eax, cl                  ;Multiply 128 bytes per sector by multiplier
    mov ecx, eax
    mov al, byte [rsi + 8]  ;Fill byte for format
    mov rdi, sectorbuffer       ;Large enough buffer
    rep stosb                   ;Create mock sector

    mov cl, byte [rsi + 4]  ;Get sectors per track
    movzx ebp, cl               ;Put number of sectors in Cylinder in ebp

    pop rcx                     ;Get back Cylinder number in ch
    mov cl, 1                   ;Ensure start at sector 1 of Cylinder

    call .convertCHSLBA ;Converts to valid 32 bit LBA in ecx for geometry type
    ;ecx now has LBA
.formatcommon:
    call .i33ehciGetDevicePtr
    jc .fbad
    mov edx, ecx    ;Load edx for function call
;Replace this section with a single USB function
    call USB.ehciAdjustAsyncSchedCtrlr
    mov rbx, sectorbuffer
.f0:
    call USB.ehciMsdBOTOutSector512
    jc .sebadBB
    inc edx ;Inc LBA
    dec ebp ;Dec number of sectors to act on
    jnz .f0
    clc
.formatexit:
    pop rbp
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    mov ah, byte [msdStatus]
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.fbadBB:
    mov byte [msdStatus], 0BBh  ;Unknown Error, request sense
.fbad:
    stc
    jmp short .formatexit
.lbaread:
    push rdi
    mov rdi, USB.ehciMsdBOTInSector512
    call .lbaCommon
    pop rdi
    mov ah, byte [msdStatus]    ;Return Error code in ah
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq   
.lbawrite:
    push rdi
    mov rdi, USB.ehciMsdBOTOutSector512
    call .lbaCommon
    pop rdi
    mov ah, byte [msdStatus]    ;Return Error code in ah
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.lbaverify:
    push rdi
    mov rdi, USB.ehciMsdBOTVerify
    call .lbaCommon
    pop rdi
    mov ah, byte [msdStatus]    ;Return Error code in ah
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.lbaformat:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push rbp
    movzx ebp, al ;Save the number of sectors to format in ebp
    push rcx
    push rdx
    mov ecx, 200h
    mov rdi, sectorbuffer
    mov rdx, qword [diskDptPtr]
    mov al, byte [rdx + 8]  ;Fill byte for format
    rep stosb
    pop rdx
    pop rcx
    jmp .formatcommon

.lbaCommon:
    push rax
    push rsi
    push rbx
    push rcx
    push rdx
    push rbp
    test al, al
    jz .se2 ;If al=0, skip copying sectors, clears CF
    movzx ebp, al
    jmp .seCommon

;Low level format, ah=07h
.formatLowLevel:
    push rsi
    push rax
    call .i33ehciGetDevicePtr   ;al = bus num, rsi = ehci device structure ptr
    call USB.ehciMsdBOTFormatUnit
    pop rax
    pop rsi
    mov ah, byte [msdStatus]
    jc .rsbad
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.lbareadparams:
;Reads drive parameters (for drive dl which is always valid at this point)
;Output: rax = dBlockSize (Dword for LBA block size)
;        rcx = qLastLBANum (Qword address of last LBA)
    push rdx
    movzx rax, dl   ;Move drive number offset into rax
    mov rdx, int33TblEntrySize
    mul rdx
    lea rdx, qword [diskDevices + rax]  ;Move address into rdx
    mov eax, dword [rdx + 3]    ;Get dBlockSize for device
    mov rcx, qword [rdx + 7]    ;Get qLastLBANum for device
    pop rdx
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.sectorsEHCI:
;Input: rdi = Address of USB EHCI MSD BBB function
;Output: CF = CY: Error, exit
;        CF = NC: No Error
    push rax
    push rsi
    push rbx
    push rcx
    push rdx
    push rbp
    test al, al
    jz .se2 ;If al=0, skip copying sectors, clears CF
    movzx ebp, al   ;Move the number of sectors into ebp
    call .convertCHSLBA ;Converts to valid 32 bit LBA in ecx for geometry type
    ;ecx now has LBA
.seCommon:  ;Entered with ebp = Number of Sectors and ecx = Start LBA
    call .i33ehciGetDevicePtr
    jc .sebad
    mov rdx, rcx    ;Load edx for function call
;Replace this section with a single USB function
    call USB.ehciAdjustAsyncSchedCtrlr
    xor al, al      ;Sector counter
.se1:
    inc al  ;Inc Sector counter
    push rax
    call rdi
    pop rax
    jc .sebadBB
    add rbx, 200h   ;Goto next sector
    inc rdx ;Inc LBA
    dec ebp ;Dec number of sectors to act on
    jnz .se1
    clc
.se2:
    pop rbp
    pop rdx
    pop rcx
    pop rbx
    pop rsi
    pop rax
    ret
.sebadBB:
    mov byte [msdStatus], 0BBh  ;Unknown Error, request sense
.sebad:
    stc
    jmp short .se2

.i33ehciGetDevicePtr:
;Input: dl = Int 33h number whose 
;Output: rsi = Pointer to ehci msd device parameter block
;        al = EHCI bus the device is on
    push rbx    ;Need to temporarily preserve rbx
    movzx rax, dl   ;Move drive number offset into rax
    mov rdx, int33TblEntrySize
    mul rdx
    lea rdx, qword [diskDevices + rax]  ;Move address into rdx
    cmp byte [rdx], 0   ;Check to see if the device type is 0 (ie doesnt exist)
    jz .i33egdpbad ;If not, exit
    mov ax, word [rdx + 1]  ;Get address/Bus pair into ax
    call USB.ehciGetDevicePtr   ;Get device pointer into rsi
    mov al, ah          ;Get the bus into al
    pop rbx
    clc
    ret
.i33egdpbad:
    stc
    ret

.convertCHSLBA:
;Converts a CHS address to LBA
;Input: dl = Drive number, if dl < 80h, use diskdpt. If dl > 80h, use hdiskdpt
;       ch = Track number, cl = Sector number, dh = Head number 
;Output: ecx = LBA address
;----------Reference Equations----------
;C = LBA / (HPC x SPT)
;H = (LBA / SPT) mod HPC
;S = (LBA mod SPT) + 1
;+++++++++++++++++++++++++++++++++++++++
;LBA = (( C x HPC ) + H ) x SPT + S - 1
;---------------------------------------
;Use diskdpt.spt for sectors per track value! 
;1.44Mb geometry => H=2, C=80, S=18
    push rax
    push rsi
    mov rsi, qword [diskDptPtr]
    shl ch, 1   ;Multiply by HPC=2
    add ch, dh  ;Add head number
    mov al, ch  ;al = ch = (( C x HPC ) + H )
    mul byte [rsi + 4]  ;Sectors per track
    xor ch, ch  
    add ax, cx  ;Add sector number to ax
    dec ax
    movzx ecx, ax
    pop rsi
    pop rax
    ret
.deviceChanged:
;Entry: dl = Drive number
;Exit: ah = 00h, No device changed occured, CF = CN
;      ah = 01h, Device changed occured, CF = CN
;      CF = CY if an error occured or device removed
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11

    push rax

    movzx r11, byte [msdStatus] ;Preserve the original status byte
    movzx ebp, dl               ;Save the device number in ebp
    call .i33ehciGetDevicePtr   ;Get MSD dev data block ptr in rsi and bus in al
;Check port on device for status change.
    cmp byte [rsi + 2], 0   ;Check if root hub
    jz .dcRoot
;External Hub procedure
    mov ax, word [rsi + 1]  ;Get bus and host hub address
    xchg al, ah             ;Swap endianness
    mov r9, rsi
    call USB.ehciGetDevicePtr   ;Get the hub address in rsi
    mov al, ah
    call USB.ehciAdjustAsyncSchedCtrlr
    mov dword [ehciDataIn], 0
    mov rdx, 00040000000000A3h ;Get Port status
    movzx ebx, byte [r9 + 3]    ;Get the port number from device parameter block
    shl rbx, 4*8    ;Shift port number to right position
    or rbx, rdx
    movzx ecx, byte [rsi + 4]  ;bMaxPacketSize0
    mov al, byte [rsi]      ;Get upstream hub address
    call USB.ehciGetRequest
    jc .dcError

    mov r8, USB.ehciEnumerateHubPort    ;Store address for if bit is set
    mov edx, dword [ehciDataIn]
    and edx, 10000h ;Isolate the port status changed bit
    shr edx, 10h    ;Shift status from bit 16 to bit 0
.dcNoError:
    mov byte [msdStatus], r11b  ;Return back the original status byte
    pop rax
    mov ah, dl                  ;Place return value in ah
    call .dcRetPop
    and byte [rsp + 2*8h], 0FEh ;Clear CF
    iretq
.dcError:
    pop rax ;Just return the old rax value
    call .dcRetPop
    or byte [rsp + 2*8h], 1    ;Set Carry flag on for invalid function
    iretq
.dcRetPop:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.dcRoot:
;Root hub procedure.
    call USB.ehciAdjustAsyncSchedCtrlr  ;Reset the bus if needed
    call USB.ehciGetOpBase      ;Get opbase into rax
    movzx ebx, byte [rsi + 3]   ;Get MSD port number into dl
    dec ebx                     ;Reduce by one
    mov edx, dword [eax + 4*ebx + ehciportsc]  ;Get port status into eax
    and dl, 2h      ;Only save bit 1, status changed bit
    shr dl, 1       ;Shift down by one bit
    jmp short .dcNoError    ;Exit
.busScan:
;Will request the hub bitfield from the RMH the device is plugged in to.
;Preserves ALL registers.
;dl = Device number

;If status changed bit set, call appropriate enumeration function.
;If enumeration returns empty device, keep current device data blocks in memory,
; but return Int 33h error 40h = Seek operation Failed.
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11

    movzx r11, byte [msdStatus] ;Preserve the original status

    movzx ebp, dl               ;Save the device number in ebp
    call .i33ehciGetDevicePtr   ;Get MSD dev data block ptr in rsi and bus in al
;Check port on device for status change.
    cmp byte [rsi + 2], 0   ;Check if root hub
    jz .bsRoot
;External Hub procedure
    mov ax, word [rsi + 1]  ;Get bus and host hub address
    xchg al, ah             ;Swap endianness
    mov r9, rsi
    call USB.ehciGetDevicePtr   ;Get the hub address in rsi
    mov al, ah
    call USB.ehciAdjustAsyncSchedCtrlr
    mov dword [ehciDataIn], 0
    mov rdx, 00040000000000A3h ;Get Port status
    movzx ebx, byte [r9 + 3]    ;Get the port number from device parameter block
    shl rbx, 4*8    ;Shift port number to right position
    or rbx, rdx
    movzx ecx, byte [rsi + 4]  ;bMaxPacketSize0
    mov al, byte [rsi]      ;Get upstream hub address
    call USB.ehciGetRequest
    jc .bsErrorExit

    mov r8, USB.ehciEnumerateHubPort    ;Store address for if bit is set
    mov edx, dword [ehciDataIn]
    and edx, 10001h
    test edx, 10000h
    jnz .bsClearPortChangeStatus    ;If top bit set, clear port change bit
.bsret:
    test dl, 1h
    jz .bsrExit06h  ;Bottom bit not set, exit media changed Error (edx = 00000h)
.bsexit:    ;The fall through is (edx = 00001h), no change to dev in port
    mov byte [msdStatus], r11b  ;Get back the original status byte
.bsErrorExit:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.bsrExit06h:    ;If its clear, nothing in port, return media changed error
    mov r11, 06h ;Change the msdStatus byte, media changed or removed
    stc
    jmp short .bsexit
.bsClearPortChangeStatus:
    push rdx
    mov dword [ehciDataIn], 0
    mov rdx, 0000000000100123h  ;Set Port status
    movzx ebx, byte [r9 + 3]    ;Get the port number from device parameter block
    shl rbx, 4*8    ;Shift port number to right position
    or rbx, rdx
    movzx ecx, byte [rsi + 4]  ;bMaxPacketSize0
    mov al, byte [rsi]      ;Get device address
    call USB.ehciSetNoData
    pop rdx
    jc .bsErrorExit  ;If error exit by destroying the old msdStatus

    test dl, 1h
    jz .bsrExit06h  ;Bottom bit not set, exit media changed error (edx = 10000h)
    jmp short .bsCommonEP   ;Else new device in port needs enum (edx = 10001h)
.bsRtNoDev:
    or dword [eax + 4*ebx + ehciportsc], 2  ;Clear the bit
    jmp short .bsrExit06h   ;Exit with seek error
.bsRoot:
;Root hub procedure.
    call USB.ehciAdjustAsyncSchedCtrlr  ;Reset the bus if needed
    call USB.ehciGetOpBase      ;Get opbase into rax
    movzx ebx, byte [rsi + 3]   ;Get MSD port number into dl
    dec ebx                     ;Reduce by one
    mov edx, dword [eax + 4*ebx + ehciportsc]  ;Get port status into eax
    and dl, 3h      ;Only save bottom two bits
    test dl, dl     ;No device in port  (dl=00b)
    jz .bsrExit06h  ;Exit media changed error
    dec dl          ;Device in port     (dl=01b)
    jz .bsexit      ;Exit, no status change
    dec dl          ;New device, Device removed from port   (dl=10b)
    jz .bsRtNoDev   ;Clear state change bit and exit Seek error
;Fallthrough case, New device, Device inserted in port  (dl=11b)
    or dword [eax + 4*ebx + ehciportsc], 2  ;Clear the state change bit
    mov r8,  USB.ehciEnumerateRootPort   ;The enumeration function to call
    mov r9, rsi        ;Store the device pointer in r9
    mov esi, 0         ;Store 0 for root hub parameter block                 
.bsCommonEP:
;Invalidate USB MSD and Int 33h table entries for device
;r9 has device pointer block and rsi has host hub pointer (if on RMH)
    mov bx, word [r9]          ;bl = Address, bh = Bus
    mov dh, bh                 ;dh = Bus
    mov dl, byte [r9 + 3]      ;dl = Device Port
    movzx r10, byte [r9 + 2]   ;r10b = Host hub address (0 = Root hub)
    mov ax, bx                 ;ax needs a copy for RemoveDevFromTables
    call USB.ehciRemoveDevFromTables    ;Removes device from USB tables
    xchg ebp, edx                       ;device number -><- bus/dev pair
    call .i33removeFromTable            ;Removes device from Int 33h table
    xchg ebp, edx                       ;bus/dev pair -><- device number
;Devices enumerated, time to reenumerate!
    mov ecx, 3
    test esi, esi   ;Is device on root hub?
    jnz .bsr0
    dec dl  ;Recall that device port must be device port - 1 for Root hub enum
.bsr0:
    call r8
    jz .bsr1
    cmp byte [msdStatus], 20h   ;General Controller Failure?
    je .bsrFail
    dec ecx
    jnz .bsr0
    jmp short .bsrFail
.bsr1:
    xchg r9, rsi    ;MSD parameter blk -><- Hub parameter blk (or 0 if root)
    call USB.ehciMsdInitialise
    test al, al
    jnz .bsrFail    ;Exit if the device failed to initialise
;Multiply dl by int33TblEntrySize to get the address to write Int33h table
    mov edx, ebp    ;Move the device number into edx (dl)
    mov eax, int33TblEntrySize  ;Zeros the upper bytes
    mul dl  ;Multiply dl by al. ax has offset into diskDevices table
    add rax, diskDevices
    mov rdi, rax    ;Put the offset into the table into rdi
    call .deviceInit
    test al, al
    jz .bsexit  ;Successful, exit!
    cmp al, 3
    je .bsexit  ;Invalid device type, but ignore for now
.bsrFail:
    mov r11, 20h ;Change the msdStatus byte to Gen. Ctrlr Failure
    stc
    jmp .bsexit
.deviceInit:    
;Further initialises an MSD device for use with the int33h interface.
;Adds device data to the allocated int33h data table.
;Input: rdi = device diskDevice ptr (given by device number*int33TblEntrySize)
;       rsi = device MSDDevTbl entry (USB address into getDevPtr)
;Output: al = 0 : Device added successfully
;        al = 1 : Bus error
;        al = 2 : Read Capacities/Reset recovary failed after 10 attempts
;        al = 3 : Invalid device type (Endpoint size too small, temporary)
;   rax destroyed
;IF DEVICE HAS MAX ENDPOINT SIZE 64, DO NOT WRITE IT TO INT 33H TABLES
    push rcx
    mov al, 3   ;Invalid EP size error code
    cmp word [rsi + 9], 200h  ;Check IN max EP packet size
    jne .deviceInitExit
    cmp word [rsi + 12], 200h ;Check OUT max EP packet size
    jne .deviceInitExit

    mov al, byte [rsi + 1]  ;Get bus number
    call USB.ehciAdjustAsyncSchedCtrlr
    mov al, 1       ;Bus error exit
    jc .deviceInitExit
    mov ecx, 10
.deviceInitReadCaps:
    call USB.ehciMsdBOTReadCapacity10   ;Preserve al error code
    cmp byte [msdStatus], 20h   ;General Controller Failure
    je .deviceInitExit
    call USB.ehciMsdBOTCheckTransaction
    test ax, ax     ;Clears CF
    jz .deviceInitWriteTableEntry   ;Success, write table entry
    call USB.ehciMsdBOTResetRecovery    ;Just force a device reset
    cmp byte [msdStatus], 20h   ;General Controller Failure
    je .deviceInitExit
    dec ecx
    jnz .deviceInitReadCaps
    mov al, 2   ;Non bus error exit
    stc ;Set carry, device failed to initialise properly
    jmp short .deviceInitExit
.deviceInitWriteTableEntry:
    mov byte [rdi], 1   ;MSD USB device signature

    mov ax, word [rsi]  ;Get address and bus into ax
    mov word [rdi + 1], ax  ;Store in Int 33h table

    mov eax, dword [ehciDataIn + 4] ;Get LBA block size
    bswap eax
    mov dword [rdi + 3], eax

    mov eax, dword [ehciDataIn] ;Get zx qword LastLBA
    bswap eax
    mov qword [rdi + 7], rax

    mov byte [rdi + 15], 2  ;Temporary, only accept devices with 200h EP sizes
    xor al, al 
.deviceInitExit:
    pop rcx
    ret
.i33removeFromTable:
;Uses Int 33h device number to invalidate the device table entry
;Input: dl = Device number
;Output: Nothing, device entry invalidated
    push rax
    push rdx
    mov al, int33TblEntrySize
    mul dl  ;Multiply tbl entry size by device number, offset in ax
    movzx rax, ax
    mov byte [diskDevices + rax], 0 ;Invalidate entry
    pop rdx
    pop rax
    ret

diskdpt:   ;Imaginary floppy disk parameter table with disk geometry. 
;For more information on layout, see Page 3-26 of IBM BIOS ref
;Assume 2 head geometry due to emulating a floppy drive
.fsb:   db 0    ;First specify byte
.ssb:   db 0    ;Second specify byte
.tto:   db 0    ;Number of timer ticks to wait before turning off drive motors
.bps:   db 2    ;Number of bytes per sector in multiples of 128 bytes, editable.
                ; 0 = 128 bytes, 1 = 256 bytes, 2 = 512 bytes etc
                ;Left shift 128 by bps to get the real bytes per sector
.spt:   db 9    ;Sectors per track
.gpl:   db 0    ;Gap length
.dtl:   db 0    ;Data length
.glf:   db 0    ;Gap length for format
.fbf:   db 0FFh ;Fill byte for format
.hst:   db 0    ;Head settle time in ms
.mst:   db 1    ;Motor startup time in multiples of 1/8 of a second.

fdiskdpt: ;Fixed drive table, only cyl, nhd and spt are valid. 
;           This schema gives roughly 8.42Gb of storage.
;           All fields with 0 in the comments are reserved post XT class BIOS.
.cyl:   dw  1024    ;1024 cylinders
.nhd:   db  255     ;255 heads
.rwc:   dw  0       ;Reduced write current cylinder, 0
.wpc:   dw  -1      ;Write precompensation number (-1=none)
.ecc:   db  0       ;Max ECC burst length, 0
.ctl:   db  08h     ;Control byte (more than 8 heads)
.sto:   db  0       ;Standard timeout, 0
.fto:   db  0       ;Formatting timeout, 0
.tcd:   db  0       ;Timeout for checking drive, 0
.clz:   dw  1023    ;Cylinder for landing zone
.spt:   db  63      ;Sectors per track
.res:   db  0       ;Reserved byte
;------------------------End of Interrupt------------------------