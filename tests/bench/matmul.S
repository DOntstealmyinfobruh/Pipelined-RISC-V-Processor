# matmul.S - 8x8 signed integer matrix multiply C = A * B.
# RV32I has no multiplier, so products use a shift-and-add routine.
# The result is reduced to a weighted checksum sum(C[i][j] * (i*8+j+1)).

    .data
    .align 2
A:
    .word -7, -2, 3, 8, -4, 1, 6, -6
    .word -4, 1, 6, -6, -1, 4, -8, -3
    .word -1, 4, -8, -3, 2, 7, -5, 0
    .word 2, 7, -5, 0, 5, -7, -2, 3
    .word 5, -7, -2, 3, 8, -4, 1, 6
    .word 8, -4, 1, 6, -6, -1, 4, -8
    .word -6, -1, 4, -8, -3, 2, 7, -5
    .word -3, 2, 7, -5, 0, 5, -7, -2
B:
    .word -3, -1, 1, 3, 5, -6, -4, -2
    .word 4, 6, -5, -3, -1, 1, 3, 5
    .word -2, 0, 2, 4, 6, -5, -3, -1
    .word 5, -6, -4, -2, 0, 2, 4, 6
    .word -1, 1, 3, 5, -6, -4, -2, 0
    .word 6, -5, -3, -1, 1, 3, 5, -6
    .word 0, 2, 4, 6, -5, -3, -1, 1
    .word -6, -4, -2, 0, 2, 4, 6, -5
C:  .space 256
    .equ N, 8
    .equ EXPECTED, -1264

    .text
_start:
    li   sp, 0x8000
    la   s0, A
    la   s1, B
    la   s2, C
    li   s3, 0                 # i
loop_i:
    li   s4, 0                 # j
loop_j:
    li   s5, 0                 # k
    li   s6, 0                 # acc
loop_k:
    # a = A[i][k]
    slli t0, s3, 3
    add  t0, t0, s5
    slli t0, t0, 2
    add  t0, t0, s0
    lw   a0, 0(t0)
    # b = B[k][j]
    slli t1, s5, 3
    add  t1, t1, s4
    slli t1, t1, 2
    add  t1, t1, s1
    lw   a1, 0(t1)
    call mul32
    add  s6, s6, a0
    addi s5, s5, 1
    li   t2, N
    blt  s5, t2, loop_k
    # C[i][j] = acc
    slli t0, s3, 3
    add  t0, t0, s4
    slli t0, t0, 2
    add  t0, t0, s2
    sw   s6, 0(t0)
    addi s4, s4, 1
    li   t2, N
    blt  s4, t2, loop_j
    addi s3, s3, 1
    blt  s3, t2, loop_i

    # ---- weighted checksum
    li   gp, 1
    li   s3, 0                 # index
    li   s6, 0                 # checksum
    mv   s7, s2
csum:
    lw   a0, 0(s7)
    addi a1, s3, 1
    call mul32
    add  s6, s6, a0
    addi s7, s7, 4
    addi s3, s3, 1
    li   t2, 64
    blt  s3, t2, csum
    li   t3, EXPECTED
    bne  s6, t3, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall

# a0 = a0 * a1 (low 32 bits; correct for signed operands too)
mul32:
    li   t5, 0
1:  andi t6, a1, 1
    beqz t6, 2f
    add  t5, t5, a0
2:  slli a0, a0, 1
    srli a1, a1, 1
    bnez a1, 1b
    mv   a0, t5
    ret
