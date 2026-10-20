# jump.S - JAL / JALR link values and targets, JALR LSB clearing,
# call/ret through a small call chain.

    .text
_start:
    # ---- JAL writes pc+4 and jumps
    li   gp, 1
    jal  ra, 1f
here1:
    j    fail
1:  la   t0, here1
    bne  ra, t0, fail

    # ---- JAL with rd = x0 does not write
    li   gp, 2
    jal  zero, 1f
    j    fail
1:  bne  zero, x0, fail

    # ---- JALR with offset
    li   gp, 3
    la   t0, target3
    jalr t1, -4(t0)            # lands on the instruction before target3
here3:
    j    fail
    j    fail
    j    target3_ok            # target3 - 4
target3:
    j    fail
target3_ok:
    la   t2, here3
    bne  t1, t2, fail

    # ---- JALR clears bit 0 of the target
    li   gp, 4
    la   t0, target4
    addi t0, t0, 1             # odd address
    jalr ra, 0(t0)
    j    fail
target4:

    # ---- JALR where rd == rs1
    li   gp, 5
    la   t0, target5
    jalr t0, 0(t0)
here5:
    j    fail
target5:
    la   t1, here5
    bne  t0, t1, fail

    # ---- call / ret through two levels
    li   gp, 6
    li   sp, 0x8000
    li   a1, 7
    call double_plus_one       # 7 -> 15 -> 31 via nested call
    li   t0, 31
    bne  a1, t0, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall

# a1 = 2*(2*a1 + 1) + 1, uses a nested call to exercise ra save/restore
double_plus_one:
    addi sp, sp, -4
    sw   ra, 0(sp)
    call dp1_leaf
    call dp1_leaf
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret
dp1_leaf:
    slli a1, a1, 1
    addi a1, a1, 1
    ret
