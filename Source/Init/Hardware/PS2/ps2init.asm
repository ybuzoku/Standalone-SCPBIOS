;----------------------------------------------------------------
;             PS/2 Keyboard Initialisation procedure            :
;----------------------------------------------------------------
keybsetup:
    mov rbp, ps2Str.startMsg
    mov rax, 1304h    ;print 0 terminated string
    xor bh, bh
    int 30h
;----------------------------------------------------------------
;Do all writes using ps2talk:
;    .rStat - Read Status port into al
;    .rDat - Read Data port into al
;    .wCmd - Write al into Command port 
;    .wDat - Write al into Data port
;----------------------------------------------------------------
;Step 1
    mov al, 0ADh
    call ps2talk.wCmd
    mov al, 0A7h        ;Cancel second interface if it exists (DO NOT REENABLE)
    call ps2talk.wCmd
;Step 2
    mov cl, 10h
initFlush:
    in al, ps2data     ;manually flush ps2data port
    dec cl
    jnz initFlush
;Step 3
keyb0:
    mov al, 20h
    call ps2talk.wCmd    ;out ps2command, al
    call ps2talk.rDat    ;Read config byte into al
;Step 4
    mov bl, al        ;copy al into bl to check for bit 2
    and bl, 0BCh      ;Disable translation, enable later
;Step 5
    mov al, 60h
    call ps2talk.wCmd    ;Write config byte command
    mov al, bl
    call ps2talk.wDat    ;Out new config byte
;Step 6
    mov al, 0AAh ;Can reset the config byte, out bl to ps2data at end of stage
    call ps2talk.wCmd
    call ps2talk.rDat
    cmp al, 55h
    jne ps2error
    
    mov al, 60h  ;Previous code may have reset our new config byte, resend it!
    call ps2talk.wCmd            ;Write config byte command
    mov al, bl
    call ps2talk.wDat            ;Out new config byte
;Step 7
    mov al, 0ABh            ;Test port 1
    call ps2talk.wCmd
    call ps2talk.rDat
    test al, al             ;Check al is zero
    jnz ps2error
;Step 8
    mov al, 0AEh            ;Enable port 1
    call ps2talk.wCmd
;Step 9
    xor ecx, ecx
keyb1:
    dec cl ;timeout counter
    jz ps2error
    mov al, 0FFh        ;Reset device
    call ps2talk.wDat
.k1:
    call ps2talk.rDat   ;read from ps2data
    cmp al, 0FAh
    jne keyb1           ;If not ACK, restart the process
    call ps2talk.rDat   ;Now read operation status 
    cmp al, 0AAh        
    jne keyb1           ;If not success, restart the whole process
    
;Step 10
keyb2:
    mov al, 0EEh     ;Echo command
    call ps2talk.wDat
    xor al, al       ;Zero al to ensure that the result is EEh
.k1:
    call ps2talk.rDat
    cmp al, 0EEh
    je keyb3           ;If equal, continue
    lea rbp, ps2Str.noecho
    mov ax, 1304h
    xor bh, bh
    int 30h

keyb3:    ;Set typematic rate/delay, 250ms, 30 reports/second
    mov al, 0F3h     ;Set typematic rate
    call ps2talk.wDat
    call ps2talk.rDat
    xor al, al       ;Set rate
    call ps2talk.wDat
    xor cl, cl
.k1:
    dec cl
    jz ps2error
    call ps2talk.rDat
    cmp al, 0FAh    ;Ack?
    jnz .k1

keyb4:      ;Set scancode 2
    mov cl, -1
    mov bl, 2   ;Scancode 2
.k1:
    dec cl
    jz ps2error
    mov al, 0F0h    ;Scancode command
    call ps2talk.wDat
    call ps2talk.rDat
    cmp al, 0FAh    ;Ack?
    jne .k1

    mov cl, -1
.k2:
    dec cl
    jz ps2error
    mov al, bl  ;Get scancode set into al
    call ps2talk.wDat
    call ps2talk.rDat
    cmp al, 0FAh    ;Ack?   
    jne .k1 ;Restart the whole process

    mov cl, -1
keyb5:
;Enable the keyboard to transmit scancodes
    dec cl
    jz ps2error
    mov al, 0F4h    ;Enable scanning
    call ps2talk.wDat
    call ps2talk.rDat
    cmp al, 0FAh    ;Ack?
    jne keyb5

keybinitend:
;Enable scancode translation and enable Interrupts on port 1
    mov al, 20h      ;Get command byte from command port
    call ps2talk.wCmd  ;al should contain command byte
    call ps2talk.rDat
    mov ah, al       ;temp save cmd byte in ah
    ;Set translate bit on and set scancode 2
    or ah, 41h  ;Set translate on and IRQ on port 1 on
    and ah, 0EFh    ;Clear bit 4, to set port clock on
    mov al, 60h
    call ps2talk.wCmd
    mov al, ah  ;Move command with bit set into al
    call ps2talk.wDat   ;And send

;Unmask IRQ1 here
    in al, pic1data
    and al, 0FDh    ;Unmask bit 1
    out pic1data, al
;Now keep looping until the keyboard buffer is empty
.cleanBuffer:
    mov ah, 01
    int 36h
    jz endPS2Init
    xor ah, ah
    int 36h
    jmp .cleanBuffer
;Relevant Procs for PS/2 keyboard setup
ps2talk:
;    .rStat - Read Status port into al
;    .rDat - Read Data port into al
;    .wCmd - Write al into Command port 
;    .wDat - Write al into Data port
.rStat:
    in al, ps2status
    ret
.rDat:
    jmp short $ + 2
    in al, ps2status
    test al, 1    ;Can something be read from KB?
    jz .rDat        ;Zero if no. Not zero = read.
    jmp short $ + 2
    in al, ps2data  ;Read it in
    ret
.wCmd:
    call ps2wait    ;preserves ax
    out ps2command, al
    ret
.wDat:
    call ps2wait
    out ps2data, al
    ret
ps2error:
    mov al, -1  ;MASK IRQ lines if error
    out pic1data, al
    out pic2data, al
    pause
    hlt
    jmp short ps2error
ps2Str:
.noecho  db "No Echo recieved ", 0
.startMsg db 0Ah, 0Dh,'PS/2 Keyboard... ',0 
.okMsg  db "OK",0Ah,0Dh,0
endPS2Init:
    mov rbp, ps2Str.okMsg
    mov rax, 1304h    ;print 0 terminated string
    xor bh, bh
    int 30h
;----------------------------------------------------------------
;                      End of Initialisation                    :
;----------------------------------------------------------------