# forwarding.S - every data-hazard path through the pipeline.
#
# Distances below are counted in instructions between producer and
# consumer: "dist 1" means back-to-back (producer in MEM when consumer is
# in EX -> EX/MEM forward), "dist 2" means one instruction in between
# (producer in WB -> MEM/WB forward), "dist 3" is covered by the register
# file write-through.

    .data
    .align 2
vals:   .word 100, 200, 300, 400
scratch:.space 32

    .text
_start:
    la   s0, vals
    la   s1, scratch

    # ------------------------------------------------------------------
    # 1. EX/MEM -> EX on rs1 and rs2 (dist 1)
    # ------------------------------------------------------------------
    li   gp, 1
    li   t0, 5
    addi t1, t0, 3             # t1 = 8   (rs1 from EX/MEM)
    add  t2, t0, t1            # t2 = 13  (rs2 from EX/MEM, rs1 from MEM/WB)
    li   t3, 13
    bne  t2, t3, fail

    # ------------------------------------------------------------------
    # 2. MEM/WB -> EX (dist 2)
    # ------------------------------------------------------------------
    li   gp, 2
    li   t0, 7
    nop
    addi t1, t0, 1             # t1 = 8
    li   t3, 8
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 3. Register-file write-through (dist 3)
    # ------------------------------------------------------------------
    li   gp, 3
    li   t0, 9
    nop
    nop
    addi t1, t0, 1
    li   t3, 10
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 4. Newest producer wins when EX/MEM and MEM/WB both match
    # ------------------------------------------------------------------
    li   gp, 4
    li   t0, 1
    li   t0, 2
    li   t0, 3                 # three writes to t0 in a row
    addi t1, t0, 0             # must see 3, not 2 or 1
    li   t3, 3
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 5. Same register on both operands
    # ------------------------------------------------------------------
    li   gp, 5
    li   t0, 21
    add  t1, t0, t0
    li   t3, 42
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 6. x0 must never be forwarded
    # ------------------------------------------------------------------
    li   gp, 6
    addi zero, zero, 55        # "result" 55 headed for x0
    add  t1, zero, zero        # must read 0
    bne  t1, zero, fail
    addi zero, zero, 77
    nop
    add  t1, zero, zero        # MEM/WB path also blocked for x0
    bne  t1, zero, fail

    # ------------------------------------------------------------------
    # 7. Long dependency chain (every instruction forwards)
    # ------------------------------------------------------------------
    li   gp, 7
    li   t0, 1
    slli t0, t0, 1
    addi t0, t0, 1
    slli t0, t0, 1
    addi t0, t0, 1
    slli t0, t0, 1
    addi t0, t0, 1
    xori t0, t0, 0x0f          # 15 ^ 15 = 0
    bne  t0, zero, fail

    # ------------------------------------------------------------------
    # 8. Store data forwarded from the previous instruction
    # ------------------------------------------------------------------
    li   gp, 8
    li   t0, 0x1234
    sw   t0, 0(s1)             # rs2 (data) from EX/MEM
    lw   t1, 0(s1)
    bne  t1, t0, fail
    li   t0, 0x5678
    nop
    sw   t0, 4(s1)             # rs2 from MEM/WB
    lw   t1, 4(s1)
    bne  t1, t0, fail

    # ------------------------------------------------------------------
    # 9. Store address forwarded
    # ------------------------------------------------------------------
    li   gp, 9
    addi t2, s1, 8
    li   t0, 0x9abc
    sw   t0, 0(t2)             # rs1 (address) from MEM/WB, rs2 from EX/MEM
    lw   t1, 8(s1)
    bne  t1, t0, fail

    # ------------------------------------------------------------------
    # 10. Load-use on rs1 -> exactly one stall, correct value
    # ------------------------------------------------------------------
    li   gp, 10
    lw   t0, 0(s0)             # 100
    addi t1, t0, 1             # load-use
    li   t3, 101
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 11. Load-use on rs2
    # ------------------------------------------------------------------
    li   gp, 11
    lw   t0, 4(s0)             # 200
    sub  t1, zero, t0
    li   t3, -200
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 12. Load one instruction before use: no stall, MEM/WB forward
    # ------------------------------------------------------------------
    li   gp, 12
    lw   t0, 8(s0)             # 300
    nop
    addi t1, t0, 0
    li   t3, 300
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 13. Load feeding a store's data (load-use on store rs2)
    # ------------------------------------------------------------------
    li   gp, 13
    lw   t0, 12(s0)            # 400
    sw   t0, 12(s1)
    lw   t1, 12(s1)
    li   t3, 400
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 14. Load feeding a load's address (pointer chase)
    # ------------------------------------------------------------------
    li   gp, 14
    sw   s0, 16(s1)            # scratch[4] = &vals
    lw   t0, 16(s1)            # t0 = &vals
    lw   t1, 4(t0)             # load-use on address -> 200
    li   t3, 200
    bne  t1, t3, fail

    # ------------------------------------------------------------------
    # 15. Branch operands forwarded (ALU result -> branch, dist 1)
    # ------------------------------------------------------------------
    li   gp, 15
    li   t0, 4
    addi t1, t0, -4            # 0
    beqz t1, 1f                # must be taken
    j    fail
1:
    # ------------------------------------------------------------------
    # 16. Load -> branch (load-use into the comparator)
    # ------------------------------------------------------------------
    li   gp, 16
    lw   t0, 0(s0)
    li   t1, 100
    beq  t0, t1, 1f            # dist 2 after load
    j    fail
1:  lw   t0, 0(s0)
    bne  t0, t1, fail          # dist 1 after load (stall)

    # ------------------------------------------------------------------
    # 17. JALR target forwarded
    # ------------------------------------------------------------------
    li   gp, 17
    la   t0, 1f
    jalr zero, 0(t0)           # rs1 from EX/MEM (la's addi)
    j    fail
1:  sw   t0, 20(s1)
    lw   t1, 20(s1)
    jalr zero, 16(t1)          # load-use into JALR -> lands on 2f
    j    fail
2:
    # ------------------------------------------------------------------
    # 18. JAL link value forwarded to the next instruction
    # ------------------------------------------------------------------
    li   gp, 18
    jal  t0, 1f
3:  j    fail
1:  la   t1, 3b
    bne  t0, t1, fail

    # ------------------------------------------------------------------
    # 19. LUI / AUIPC results forwarded
    # ------------------------------------------------------------------
    li   gp, 19
    lui  t0, 0x1
    addi t0, t0, 1             # 0x1001
    li   t3, 0x1001
    bne  t0, t3, fail

    # ------------------------------------------------------------------
    # 20. Two loads back to back, then use both
    # ------------------------------------------------------------------
    li   gp, 20
    lw   t0, 0(s0)             # 100
    lw   t1, 4(s0)             # 200
    add  t2, t0, t1            # t1 is load-use, t0 via MEM/WB
    li   t3, 300
    bne  t2, t3, fail

    # ------------------------------------------------------------------
    # 21. Load into a register that the next instruction overwrites
    #     (dependency on rd only, not a hazard: must not deadlock)
    # ------------------------------------------------------------------
    li   gp, 21
    lw   t0, 0(s0)
    li   t0, 5                 # WAW, no read of t0
    li   t3, 5
    bne  t0, t3, fail

    # ------------------------------------------------------------------
    # 22. Load to x0 followed by a read of x0: no stall needed, reads 0
    # ------------------------------------------------------------------
    li   gp, 22
    lw   zero, 0(s0)
    add  t1, zero, zero
    bne  t1, zero, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
