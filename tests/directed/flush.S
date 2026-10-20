# flush.S - control hazards. Instructions fetched after a taken branch or
# jump are on the wrong path; they must never write a register or memory.
# The pipeline resolves branches in EX, so the two instructions behind
# a taken branch are the ones that get flushed.

    .data
    .align 2
cell:   .word 0

    .text
_start:
    la   s1, cell
    li   s2, 0                 # wrong-path writes would show up here

    # ---- 1. taken branch: two shadow instructions must not commit
    li   gp, 1
    beq  zero, zero, 1f
    addi s2, s2, 1             # shadow slot 1 (in ID when branch is in EX)
    addi s2, s2, 2             # shadow slot 2 (in IF)
    addi s2, s2, 4
1:  bnez s2, fail

    # ---- 2. wrong-path store must not reach memory
    li   gp, 2
    sw   zero, 0(s1)
    li   t0, 0xbad
    j    1f
    sw   t0, 0(s1)             # shadow store
    sw   t0, 0(s1)
1:  lw   t1, 0(s1)
    bnez t1, fail

    # ---- 3. not-taken branch: next instructions DO commit
    li   gp, 3
    li   t0, 0
    bne  zero, zero, fail
    addi t0, t0, 1
    addi t0, t0, 1
    li   t1, 2
    bne  t0, t1, fail

    # ---- 4. back-to-back taken branches
    li   gp, 4
    beq  zero, zero, 1f
    beq  zero, zero, fail      # shadow branch must be squashed
1:  beq  zero, zero, 2f
    addi s2, s2, 1
2:  bnez s2, fail

    # ---- 5. branch in the shadow of a jump must not redirect
    li   gp, 5
    j    1f
    j    fail
    j    fail
1:
    # ---- 6. load-use stall immediately before a taken branch
    li   gp, 6
    li   t0, 7
    sw   t0, 0(s1)
    lw   t1, 0(s1)
    bne  t1, t0, fail          # stalls one cycle, not taken
    lw   t1, 0(s1)
    beq  t1, t0, 1f            # stalls one cycle, then taken
    addi s2, s2, 1
1:  bnez s2, fail

    # ---- 7. wrong-path load-use must not cause a stall-related hang
    li   gp, 7
    j    1f
    lw   t5, 0(s1)
    addi t6, t5, 1             # wrong-path load-use pair
1:  nop

    # ---- 8. tight loop with a taken backward branch every iteration
    li   gp, 8
    li   t0, 0
    li   t1, 50
1:  addi t0, t0, 1
    blt  t0, t1, 1b
    bne  t0, t1, fail

    # ---- 9. jump to the instruction right after the jump (target == pc+4)
    li   gp, 9
    li   t0, 0
    j    1f
1:  addi t0, t0, 1             # executes once
    li   t1, 1
    bne  t0, t1, fail

    # ---- 10. wrong-path ECALL must not halt the processor
    li   gp, 10
    j    1f
    ecall
1:  nop

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
