# loadstore.S - every load/store width at every legal alignment,
# sign vs zero extension, and stores that only touch their own bytes.

    .data
    .align 2
words:  .word 0x80ff7f01, 0x00000000, 0xdeadbeef, 0x00000000
buf:    .space 16

    .text
_start:
    la   s0, words

    # ---- LW
    li   gp, 1
    lw   t0, 0(s0)
    li   t1, 0x80ff7f01
    bne  t0, t1, fail
    lw   t0, 8(s0)
    li   t1, 0xdeadbeef
    bne  t0, t1, fail

    # ---- LB: bytes are 01 7f ff 80 (little endian)
    li   gp, 2
    lb   t0, 0(s0)
    li   t1, 0x01
    bne  t0, t1, fail
    lb   t0, 1(s0)
    li   t1, 0x7f
    bne  t0, t1, fail
    lb   t0, 2(s0)
    li   t1, -1
    bne  t0, t1, fail
    lb   t0, 3(s0)
    li   t1, -128
    bne  t0, t1, fail

    # ---- LBU
    li   gp, 3
    lbu  t0, 2(s0)
    li   t1, 0xff
    bne  t0, t1, fail
    lbu  t0, 3(s0)
    li   t1, 0x80
    bne  t0, t1, fail

    # ---- LH / LHU
    li   gp, 4
    lh   t0, 0(s0)
    li   t1, 0x7f01
    bne  t0, t1, fail
    lh   t0, 2(s0)
    li   t1, 0xffff80ff
    bne  t0, t1, fail
    lhu  t0, 2(s0)
    li   t1, 0x80ff
    bne  t0, t1, fail

    # ---- SW then LW
    li   gp, 5
    la   s1, buf
    li   t0, 0x11223344
    sw   t0, 0(s1)
    lw   t1, 0(s1)
    bne  t0, t1, fail

    # ---- SB into each byte lane
    li   gp, 6
    sw   zero, 4(s1)
    li   t0, 0xa1
    sb   t0, 4(s1)
    li   t0, 0xb2
    sb   t0, 5(s1)
    li   t0, 0xc3
    sb   t0, 6(s1)
    li   t0, 0x1d4             # upper bits must be ignored
    sb   t0, 7(s1)
    lw   t1, 4(s1)
    li   t2, 0xd4c3b2a1
    bne  t1, t2, fail

    # ---- SH into both halves
    li   gp, 7
    li   t0, 0xffff1234
    sh   t0, 8(s1)
    li   t0, 0x5678
    sh   t0, 10(s1)
    lw   t1, 8(s1)
    li   t2, 0x56781234
    bne  t1, t2, fail

    # ---- SB leaves neighbours untouched
    li   gp, 8
    li   t0, 0x11223344
    sw   t0, 12(s1)
    li   t0, 0
    sb   t0, 13(s1)
    lw   t1, 12(s1)
    li   t2, 0x11220044
    bne  t1, t2, fail

    # ---- negative offsets
    li   gp, 9
    addi s2, s1, 16
    lw   t0, -16(s2)
    li   t1, 0x11223344
    bne  t0, t1, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
