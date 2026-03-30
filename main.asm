.INCLUDE "m32def.inc"

;===========================================================
; RESET VECTOR
;===========================================================
.cseg
.org 0x0000
    rjmp START

;===========================================================
; REGISTER DEFINITIONS
;===========================================================
.def adc_low   = r16
.def adc_high  = r17
.def adc8      = r18       ; LM35 8-bit ADC for fan
.def rh_val    = r19       ; Humidity %
.def temp      = r20
.def tens      = r21
.def units     = r22
.def t_char    = r23
.def gas8      = r24       ; Gas sensor %

;===========================================================
; MAIN START
;===========================================================
START:
;-----------------------------------------------------------
; PWM SETUP (LM35 FAN) – PD7 / OC2
;-----------------------------------------------------------
    sbi DDRD, PD7          ; PD7 output
    ; Fast PWM, non-inverting, prescaler=8
    ldi r16, (1<<WGM20)|(1<<WGM21)|(1<<COM21)|(1<<CS21)
    out TCCR2, r16

;-----------------------------------------------------------
; OTHER OUTPUTS
; PB0 = RED LED, PB1 = BLUE LED, PB3 = Buzzer
; PD6 = Gas fan
;-----------------------------------------------------------
    ldi r16, 0b00001011    ; PB0, PB1, PB3 outputs
    out DDRB, r16
    ldi r16, 0x00
    out PORTB, r16

    sbi DDRD, PD6           ; Gas fan output

;-----------------------------------------------------------
; UART 9600 @ 8MHz
;-----------------------------------------------------------
    ldi r16, 51
    out UBRRL, r16
    clr r16
    out UBRRH, r16
    ldi r16, (1<<TXEN)
    out UCSRB, r16
    ldi r16, (1<<URSEL)|(1<<UCSZ1)|(1<<UCSZ0)
    out UCSRC, r16

;-----------------------------------------------------------
; ADC ENABLE – prescaler 128
;-----------------------------------------------------------
    ldi r16, (1<<ADEN)|(1<<ADPS2)|(1<<ADPS1)|(1<<ADPS0)
    out ADCSRA, r16

;===========================================================
; MAIN LOOP
;===========================================================
MAIN_LOOP:

;===========================================================
; 1) READ LM35 (ADC0) FOR PWM FAN
;===========================================================
    ldi r16, (1<<REFS0) | 0      ; ADC0
    out ADMUX, r16

    sbi ADCSRA, ADSC
WAIT_ADC0:
    sbis ADCSRA, ADIF
    rjmp WAIT_ADC0
    sbi ADCSRA, ADIF

    in adc_low, ADCL
    in adc_high, ADCH
    mov adc8, adc_low

;--- FAN SPEED CONTROL BASED ON LM35 ---
    cpi adc8, 50
    brlo FAN_OFF

    cpi adc8, 61
    brlo FAN_LOW

    cpi adc8, 72
    brlo FAN_MED

    rjmp FAN_HIGH

FAN_OFF:
    ldi r16, 0
    out OCR2, r16
    rjmp READ_HUMIDITY

FAN_LOW:
    ldi r16, 70
    out OCR2, r16
    rjmp READ_HUMIDITY

FAN_MED:
    ldi r16, 150
    out OCR2, r16
    rjmp READ_HUMIDITY

FAN_HIGH:
    ldi r16, 255
    out OCR2, r16

;===========================================================
; 2) READ HUMIDITY (ADC1) + LED + UART
;===========================================================
READ_HUMIDITY:
    ldi r16, (1<<REFS0)|1
    out ADMUX, r16

    sbi ADCSRA, ADSC
WAIT_ADC1:
    sbis ADCSRA, ADIF
    rjmp WAIT_ADC1
    sbi ADCSRA, ADIF

    in r17, ADCL
    in r18, ADCH
    mov r22, r17
    mov r23, r18

; COMPUTE RH% = ADC * 25 / 256
    mov r24, r22
    mov r25, r23
    ldi r30, 4
LSL4:
    lsl r24
    rol r25
    dec r30
    brne LSL4

    mov r26, r22
    mov r27, r23
    ldi r30, 3
LSL3:
    lsl r26
    rol r27
    dec r30
    brne LSL3

    add r24, r26
    adc r25, r27
    add r24, r22
    adc r25, r23

    mov rh_val, r25

; LED LOGIC
    cpi rh_val, 30
    brlo RH_LOW
    cpi rh_val, 50
    brsh RH_HIGH
    rjmp RH_NORMAL

RH_LOW:
    ldi r16, 0b00000001
    out PORTB, r16
    rjmp SEND_RH

RH_HIGH:
    ldi r16, 0b00000010
    out PORTB, r16
    rjmp SEND_RH

RH_NORMAL:
    ldi r16, 0x00
    out PORTB, r16

SEND_RH:
    ; tens
    ldi r22, 0
TEN_LOOP:
    cpi rh_val, 10
    brlo GOT_TENS
    subi rh_val, 10
    inc r22
    rjmp TEN_LOOP
GOT_TENS:
    ldi r24,'0'
    add r24,r22
    rcall UART_SEND
    ; ones
    mov r24, rh_val
    ldi r21,'0'
    add r24,r21
    rcall UART_SEND
    ; CR LF
    ldi r24,0x0D
    rcall UART_SEND
    ldi r24,0x0A
    rcall UART_SEND

;===========================================================
; 3) READ GAS SENSOR (ADC2) + FAN/BUZZER + UART
;===========================================================
    ldi r16, (1<<REFS0)|2
    out ADMUX, r16

    sbi ADCSRA, ADSC
WAIT_ADC2:
    sbis ADCSRA, ADIF
    rjmp WAIT_ADC2
    sbi ADCSRA, ADIF

    in adc_low, ADCL
    in adc_high, ADCH
    mov temp, adc_low

    ; gas8 = approx (ADC*100)/1023
    ldi r24,100
    mul temp,r24
    mov gas8,r1
    clr r1

    ; send gas % via UART
    rcall UART_SEND_STRING
    rcall UART_SEND_PERCENT
    rcall UART_SEND_STRING2

; FAN & BUZZER CONTROL (Gas sensor)
    ldi temp,50
    cp gas8,temp
    brlo SAFE
    sbi PORTD,6      ; Fan ON
    sbi PORTB,3      ; Buzzer ON
    rjmp DELAY

SAFE:
    cbi PORTD,6      ; Fan OFF
    cbi PORTB,3      ; Buzzer OFF

DELAY:
    rcall DELAY_1SEC
    rjmp MAIN_LOOP

;===========================================================
; UART SUBROUTINES
;===========================================================
UART_SEND:
WAIT_UDRE:
    in temp,UCSRA
    sbrs temp,UDRE
    rjmp WAIT_UDRE
    out UDR,r24
    ret

UART_SEND_STRING:
    ldi t_char,'G'
    rcall UART_SEND_CHAR
    ldi t_char,'a'
    rcall UART_SEND_CHAR
    ldi t_char,'s'
    rcall UART_SEND_CHAR
    ldi t_char,' '
    rcall UART_SEND_CHAR
    ldi t_char,'L'
    rcall UART_SEND_CHAR
    ldi t_char,'e'
    rcall UART_SEND_CHAR
    ldi t_char,'v'
    rcall UART_SEND_CHAR
    ldi t_char,'e'
    rcall UART_SEND_CHAR
    ldi t_char,'l'
    rcall UART_SEND_CHAR
    ldi t_char,':'
    rcall UART_SEND_CHAR
    ldi t_char,' '
    rcall UART_SEND_CHAR
    ret

UART_SEND_STRING2:
    ldi t_char,' '
    rcall UART_SEND_CHAR
    ldi t_char,'%'
    rcall UART_SEND_CHAR
    ldi t_char,0x0D
    rcall UART_SEND_CHAR
    ldi t_char,0x0A
    rcall UART_SEND_CHAR
    ret

UART_SEND_PERCENT:
    ldi tens,0
    ldi units,0
    mov temp, gas8
SEND_LOOP:
    cpi temp,10
    brlo SEND_UNITS
    subi temp,10
    inc tens
    rjmp SEND_LOOP
SEND_UNITS:
    mov units,temp
    ldi t_char,'0'
    add t_char,tens
    rcall UART_SEND_CHAR
    ldi t_char,'0'
    add t_char,units
    rcall UART_SEND_CHAR
    ret

UART_SEND_CHAR:
    in temp,UCSRA
    sbrs temp,UDRE
    rjmp UART_SEND_CHAR
    out UDR,t_char
    ret

;===========================================================
; 1 SECOND DELAY
;===========================================================
DELAY_1SEC:
    ldi r24,100
D1:
    ldi r25,250
D2:
    dec r25
    brne D2
    dec r24
    brne D1
    ret
