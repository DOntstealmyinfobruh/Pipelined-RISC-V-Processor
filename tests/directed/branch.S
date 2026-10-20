# branch.S - all six conditional branches, taken and not taken,
# including signed/unsigned edge cases and backward branches.

    .text
_start:
    li   s0, 0                 # count of correctly taken branches

    # ---- BEQ
    li   gp, 1
    li   t0, 5
    li   t1, 5
    beq  t0, t1, 1f
    j    fail
1:  addi s0, s0, 1
    li   t1, 6
    beq  t0, t1, fail

    # ---- BNE
    li   gp, 2
    bne  t0, t1, 1f
    j    fail
1:  addi s0, s0, 1
    bne  t0, t0, fail

    # ---- BLT (signed)
    li   gp, 3
    li   t0, -1
    li   t1, 1
    blt  t0, t1, 1f
    j    fail
1:  addi s0, s0, 1
    blt  t1, t0, fail
    blt  t0, t0, fail

    # ---- BGE (signed)
    li   gp, 4
    bge  t1, t0, 1f
    j    fail
1:  addi s0, s0, 1
    bge  t0, t0, 2f            # equal -> taken
    j    fail
2:  addi s0, s0, 1
    bge  t0, t1, fail

    # ---- BLTU (unsigned: 0xffffffff is large)
    li   gp, 5
    bltu t1, t0, 1f
    j    fail
1:  addi s0, s0, 1
    bltu t0, t1, fail

    # ---- BGEU
    li   gp, 6
    bgeu t0, t1, 1f
    j    fail
1:  addi s0, s0, 1
    bgeu t1, t0, fail
    bgeu zero, zero, 2f
    j    fail
2:  addi s0, s0, 1

    # ---- INT_MIN / INT_MAX
    li   gp, 7
    li   t0, 0x80000000
    li   t1, 0x7fffffff
    blt  t1, t0, fail          # signed: MAX < MIN false
    bltu t0, t1, fail          # unsigned: 0x8.. < 0x7f.. false
    blt  t0, t1, 1f
    j    fail
1:  addi s0, s0, 1

    # ---- backward branch loop: sum 1..10
    li   gp, 8
    li   t0, 10
    li   t1, 0
loop:
    add  t1, t1, t0
    addi t0, t0, -1
    bnez t0, loop
    li   t2, 55
    bne  t1, t2, fail

    # ---- pseudo branches
    li   gp, 9
    li   t0, 3
    bgtz t0, 1f
    j    fail
1:  blez t0, fail
    bgt  t0, zero, 2f
    j    fail
2:  ble  t0, zero, fail
    addi s0, s0, 2

    # ---- tally: every taken branch above must have been taken exactly once
    li   gp, 10
    li   t0, 11
    bne  s0, t0, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
