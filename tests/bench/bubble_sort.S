# bubble_sort.S - sort 32 signed words in place, then verify the array is
# ascending and that the sum is unchanged. Load-heavy inner loop with
# compare-and-swap: a good stress test for load-use stalls.

    .data
    .align 2
array:
    .word 5084, -6396, 5733, -12886, 543, -339, 3357, -4262
    .word -7974, -4123, 10668, -10725, -6626, 4703, 9491, 15984
    .word 9849, -1172, 1277, 4112, -8193, 6681, 7087, 15712
    .word -5603, -1788, 6828, 7860, -10723, -15870, 9259, -15034
    .equ N, 32
    .equ EXPECTED_SUM, 12514

    .text
_start:
    la   s0, array
    li   s1, N

    # ---- bubble sort
    addi s2, s1, -1            # outer bound
outer:
    beqz s2, sorted
    li   t0, 0                 # i
    mv   t1, s0                # &a[i]
    li   s3, 0                 # swapped?
inner:
    lw   t2, 0(t1)
    lw   t3, 4(t1)
    ble  t2, t3, noswap
    sw   t3, 0(t1)
    sw   t2, 4(t1)
    li   s3, 1
noswap:
    addi t0, t0, 1
    addi t1, t1, 4
    blt  t0, s2, inner
    beqz s3, sorted            # early exit if no swaps
    addi s2, s2, -1
    j    outer

sorted:
    # ---- check ascending order
    li   gp, 1
    mv   t1, s0
    li   t0, 1
check:
    lw   t2, 0(t1)
    lw   t3, 4(t1)
    bgt  t2, t3, fail
    addi t1, t1, 4
    addi t0, t0, 1
    blt  t0, s1, check

    # ---- check sum
    li   gp, 2
    mv   t1, s0
    li   t0, 0
    li   t4, 0
sum:
    lw   t2, 0(t1)
    add  t4, t4, t2
    addi t1, t1, 4
    addi t0, t0, 1
    blt  t0, s1, sum
    li   t5, EXPECTED_SUM
    bne  t4, t5, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall
