# alu.S - register-register and register-immediate arithmetic/logic.
# Convention for all self-checking tests: gp holds the current sub-test
# number; on mismatch jump to fail (a0 = gp), otherwise end with a0 = 0.

    .text
_start:
    # ---------------- ADD / SUB ----------------
    li   gp, 1
    li   t0, 0x7fffffff
    li   t1, 1
    add  t2, t0, t1
    li   t3, 0x80000000
    bne  t2, t3, fail          # signed overflow wraps

    li   gp, 2
    sub  t2, zero, t1
    li   t3, -1
    bne  t2, t3, fail

    li   gp, 3
    li   t0, 0x12345678
    li   t1, 0x0fedcba9
    sub  t2, t0, t1
    li   t3, 0x02468acf
    bne  t2, t3, fail

    # ---------------- logic ----------------
    li   gp, 4
    li   t0, 0xff00ff00
    li   t1, 0x0ff00ff0
    and  t2, t0, t1
    li   t3, 0x0f000f00
    bne  t2, t3, fail
    or   t2, t0, t1
    li   t3, 0xfff0fff0
    bne  t2, t3, fail
    xor  t2, t0, t1
    li   t3, 0xf0f0f0f0
    bne  t2, t3, fail

    li   gp, 5
    andi t2, t0, 0x7f0
    li   t3, 0x00000700
    bne  t2, t3, fail
    ori  t2, t0, -1
    li   t3, -1
    bne  t2, t3, fail
    xori t2, t0, -1            # NOT
    li   t3, 0x00ff00ff
    bne  t2, t3, fail

    # ---------------- shifts ----------------
    li   gp, 6
    li   t0, 0x80000001
    li   t1, 31
    sll  t2, t0, t1
    li   t3, 0x80000000
    bne  t2, t3, fail
    srl  t2, t0, t1
    li   t3, 1
    bne  t2, t3, fail
    sra  t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail

    li   gp, 7
    li   t1, 0x24              # only low 5 bits used: shift by 4
    sll  t2, t0, t1
    li   t3, 0x00000010
    bne  t2, t3, fail
    sra  t2, t0, t1
    li   t3, 0xf8000000
    bne  t2, t3, fail

    li   gp, 8
    slli t2, t0, 4
    li   t3, 0x00000010
    bne  t2, t3, fail
    srli t2, t0, 4
    li   t3, 0x08000000
    bne  t2, t3, fail
    srai t2, t0, 4
    li   t3, 0xf8000000
    bne  t2, t3, fail
    srai t2, t0, 0
    bne  t2, t0, fail

    # ---------------- compares ----------------
    li   gp, 9
    li   t0, -1
    li   t1, 1
    slt  t2, t0, t1            # -1 < 1 signed
    li   t3, 1
    bne  t2, t3, fail
    sltu t2, t0, t1            # 0xffffffff < 1 unsigned? no
    bne  t2, zero, fail
    slt  t2, t1, t1
    bne  t2, zero, fail

    li   gp, 10
    slti  t2, t0, 0            # -1 < 0
    li    t3, 1
    bne   t2, t3, fail
    sltiu t2, t1, -1           # 1 < 0xffffffff
    bne   t2, t3, fail
    sltiu t2, zero, 1          # seqz idiom
    bne   t2, t3, fail
    sltiu t2, t0, 5
    bne   t2, zero, fail

    li   gp, 11
    li   t0, 0x80000000
    li   t1, 0x7fffffff
    slt  t2, t0, t1            # INT_MIN < INT_MAX
    li   t3, 1
    bne  t2, t3, fail
    sltu t2, t0, t1
    bne  t2, zero, fail

    # ---------------- addi edges / x0 ----------------
    li   gp, 12
    addi t2, zero, 2047
    li   t3, 2047
    bne  t2, t3, fail
    addi t2, zero, -2048
    li   t3, -2048
    bne  t2, t3, fail

    li   gp, 13
    addi zero, zero, 123       # writes to x0 are discarded
    bne  zero, x0, fail
    add  t2, zero, zero
    bne  t2, zero, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
