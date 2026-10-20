# crc32.S - bitwise CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) over
# the standard check string "123456789". Expected result 0xCBF43926.
# Byte loads, shifts, XOR and data-dependent branches in a tight loop.

    .data
msg:    .byte '1', '2', '3', '4', '5', '6', '7', '8', '9'
    .equ MSG_LEN, 9

    .text
_start:
    la   s0, msg
    li   s1, MSG_LEN
    li   s2, -1                # crc = 0xffffffff
    li   s3, 0xedb88320        # reflected polynomial

byte_loop:
    lbu  t0, 0(s0)
    xor  s2, s2, t0            # load-use
    li   t1, 8
bit_loop:
    andi t2, s2, 1
    srli s2, s2, 1
    beqz t2, 1f
    xor  s2, s2, s3
1:  addi t1, t1, -1
    bnez t1, bit_loop
    addi s0, s0, 1
    addi s1, s1, -1
    bnez s1, byte_loop

    not  s2, s2
    li   gp, 1
    li   t0, 0xcbf43926
    bne  s2, t0, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
