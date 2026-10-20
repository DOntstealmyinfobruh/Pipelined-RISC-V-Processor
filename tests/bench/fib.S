# fib.S - iterative Fibonacci (tight ALU dependency chain) followed by a
# recursive Fibonacci (deep call stack: JAL/JALR, stack loads and stores).

    .text
_start:
    li   sp, 0x8000

    # ---- iterative fib(40) mod 2^32
    li   gp, 1
    li   t0, 0                 # fib(0)
    li   t1, 1                 # fib(1)
    li   t2, 40
iter:
    add  t3, t0, t1
    mv   t0, t1
    mv   t1, t3
    addi t2, t2, -1
    bnez t2, iter
    li   t4, 102334155         # fib(40)
    bne  t0, t4, fail

    # ---- recursive fib(15)
    li   gp, 2
    li   a0, 15
    call rfib
    li   t4, 610
    bne  a0, t4, fail

pass:
    li   a0, 0
    ecall
fail:
    mv   a0, gp
    ecall

# a0 = fib(a0), naive recursion
rfib:
    li   t0, 2
    blt  a0, t0, rfib_base
    addi sp, sp, -12
    sw   ra, 8(sp)
    sw   s0, 4(sp)
    sw   s1, 0(sp)
    mv   s0, a0
    addi a0, s0, -1
    call rfib
    mv   s1, a0
    addi a0, s0, -2
    call rfib
    add  a0, a0, s1
    lw   s1, 0(sp)
    lw   s0, 4(sp)
    lw   ra, 8(sp)
    addi sp, sp, 12
rfib_base:
    ret
