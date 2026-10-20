# strings.S - strlen, byte-wise memcpy, and memcmp on a short string.
# Byte loads/stores with immediate reuse of the loaded value.

    .data
src:    .byte 'p','i','p','e','l','i','n','e','d',' ','r','v','3','2','i',0
    .align 2
dst:    .space 32

    .text
_start:
    # ---- strlen(src) == 15
    li   gp, 1
    la   a0, src
    call strlen
    li   t0, 15
    bne  a0, t0, fail

    # ---- memcpy(dst, src, 16)
    li   gp, 2
    la   a0, dst
    la   a1, src
    li   a2, 16
    call memcpy

    # ---- memcmp(dst, src, 16) == 0
    la   a0, dst
    la   a1, src
    li   a2, 16
    call memcmp
    bnez a0, fail

    # ---- change one byte, memcmp must now be non-zero
    li   gp, 3
    la   t0, dst
    li   t1, 'X'
    sb   t1, 7(t0)
    la   a0, dst
    la   a1, src
    li   a2, 16
    call memcmp
    beqz a0, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall

strlen:                        # a0 = length of NUL-terminated string at a0
    mv   t0, a0
1:  lbu  t1, 0(t0)
    beqz t1, 2f                # load-use into a branch
    addi t0, t0, 1
    j    1b
2:  sub  a0, t0, a0
    ret

memcpy:                        # copy a2 bytes from a1 to a0
    beqz a2, 2f
1:  lbu  t0, 0(a1)
    sb   t0, 0(a0)             # load-use into store data
    addi a0, a0, 1
    addi a1, a1, 1
    addi a2, a2, -1
    bnez a2, 1b
2:  ret

memcmp:                        # a0 = first difference (0 if equal)
    beqz a2, 2f
1:  lbu  t0, 0(a0)
    lbu  t1, 0(a1)
    sub  t2, t0, t1            # load-use on rs2
    bnez t2, 3f
    addi a0, a0, 1
    addi a1, a1, 1
    addi a2, a2, -1
    bnez a2, 1b
2:  li   a0, 0
    ret
3:  mv   a0, t2
    ret
