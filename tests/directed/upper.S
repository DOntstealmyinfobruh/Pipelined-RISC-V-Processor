# upper.S - LUI and AUIPC, including the hi/lo rounding used by li/la.

    .text
_start:
    li   gp, 1
    lui  t0, 0x12345
    li   t1, 0x12345000
    bne  t0, t1, fail

    li   gp, 2
    lui  t0, 0xfffff
    li   t1, 0xfffff000
    bne  t0, t1, fail

    # AUIPC at a known address
    li   gp, 3
known:
    auipc t0, 0
    la   t1, known
    bne  t0, t1, fail

    li   gp, 4
here4:
    auipc t0, 1                # pc + 0x1000
    la   t1, here4
    sub  t2, t0, t1
    li   t3, 0x1000
    bne  t2, t3, fail

    # li values whose low 12 bits have bit 11 set (hi20 rounding)
    li   gp, 5
    li   t0, 0x00000800
    addi t0, t0, -1
    li   t1, 0x7ff
    bne  t0, t1, fail
    li   t0, 0x12345fff
    li   t1, 0x12346000
    addi t1, t1, -1
    bne  t0, t1, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
