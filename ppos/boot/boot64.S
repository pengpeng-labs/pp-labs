/* pp-os 64 位入口 + IDT（运行时构建）+ 中断桩 */

/* IRQ is asynchronous: preserve every GPR and compiler-visible XMM register. */
.macro ISR_STUB name, handler
.global \name
\name:
    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rbp
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
    mov %rsp, %r12
    sub $272, %rsp
    and $-16, %rsp
    movdqu %xmm0, 0(%rsp)
    movdqu %xmm1, 16(%rsp)
    movdqu %xmm2, 32(%rsp)
    movdqu %xmm3, 48(%rsp)
    movdqu %xmm4, 64(%rsp)
    movdqu %xmm5, 80(%rsp)
    movdqu %xmm6, 96(%rsp)
    movdqu %xmm7, 112(%rsp)
    movdqu %xmm8, 128(%rsp)
    movdqu %xmm9, 144(%rsp)
    movdqu %xmm10, 160(%rsp)
    movdqu %xmm11, 176(%rsp)
    movdqu %xmm12, 192(%rsp)
    movdqu %xmm13, 208(%rsp)
    movdqu %xmm14, 224(%rsp)
    movdqu %xmm15, 240(%rsp)
    cld
    call \handler
    movdqu 0(%rsp), %xmm0
    movdqu 16(%rsp), %xmm1
    movdqu 32(%rsp), %xmm2
    movdqu 48(%rsp), %xmm3
    movdqu 64(%rsp), %xmm4
    movdqu 80(%rsp), %xmm5
    movdqu 96(%rsp), %xmm6
    movdqu 112(%rsp), %xmm7
    movdqu 128(%rsp), %xmm8
    movdqu 144(%rsp), %xmm9
    movdqu 160(%rsp), %xmm10
    movdqu 176(%rsp), %xmm11
    movdqu 192(%rsp), %xmm12
    movdqu 208(%rsp), %xmm13
    movdqu 224(%rsp), %xmm14
    movdqu 240(%rsp), %xmm15
    mov %r12, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rbp
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax
    iretq
.endm

/* CPU exception frame is normalized to: vector, error, RIP, CS, RFLAGS.
   Exceptions listed by Intel as carrying an error code only push vector here. */
.macro EXC_NOERR num
.global isr_exc\num
isr_exc\num:
    pushq $0
    pushq $\num
    jmp exception_common
.endm

.macro EXC_ERR num
.global isr_exc\num
isr_exc\num:
    pushq $\num
    jmp exception_common
.endm

.section .text
.code64
.ifndef PPOS_EXCEPTION_SELFTEST
.set PPOS_EXCEPTION_SELFTEST, 0
.endif
.ifndef PPOS_ALLOCATOR_SELFTEST
.set PPOS_ALLOCATOR_SELFTEST, 0
.endif

.global entry64
entry64:
    /* Preserve Multiboot arguments delivered through boot32.S. */
    mov %edi, %r14d
    mov %esi, %r15d

    xor %rax, %rax
    mov %ax, %ss
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs

    mov $stack_top, %rsp
    xor %rbp, %rbp

    /* 启用 SSE/SSE2：OSFXSR + OSXMMEXCPT（否则 movups 等指令触发 #UD） */
    mov %cr4, %rax
    or $0x600, %rax
    mov %rax, %cr4

    call protect_kernel_sections
    call load_idt
    mov %r14, %rdi
    mov %r15, %rsi
    call kmain

halt:
    cli
    hlt
    jmp halt

/* 填充一个 IDT 门：%rdi = 表项指针，%rsi = 处理器地址 */
set_idt_gate:
    mov %rsi, %rax
    mov %ax, 0(%rdi)        /* offset[15:0] */
    movw $0x08, 2(%rdi)     /* selector = 代码段 */
    movb $0x00, 4(%rdi)     /* IST */
    movb $0x8E, 5(%rdi)     /* type_attr: present + interrupt gate */
    shr $16, %rax
    mov %ax, 6(%rdi)        /* offset[31:16] */
    shr $16, %rax
    mov %eax, 8(%rdi)       /* offset[63:32] */
    movl $0x0, 12(%rdi)     /* reserved */
    ret

/* 构建并加载 IDT */
.global load_idt
load_idt:    push %rbx
    push %r12
    push %r13

    mov $idt, %r12          /* 表项指针 */
    xor %r13, %r13          /* 向量计数器 */
1:
    mov $isr_default, %rsi
    mov %r12, %rdi
    call set_idt_gate
    add $16, %r12
    inc %r13
    cmp $256, %r13
    jne 1b

    /* CPU exceptions 0..31 use vector-specific stubs. */
    mov $exception_stub_table, %rbx
    mov $idt, %r12
    xor %r13, %r13
2:
    mov (%rbx,%r13,8), %rsi
    mov %r12, %rdi
    call set_idt_gate
    add $16, %r12
    inc %r13
    cmp $32, %r13
    jne 2b

    mov $idt + 32*16, %rdi  /* IRQ0 -> 定时器 */
    mov $isr_timer, %rsi
    call set_idt_gate

    mov $idt + 33*16, %rdi  /* IRQ1 -> 键盘 */
    mov $isr_keyboard, %rsi
    call set_idt_gate

    pop %r13
    pop %r12
    pop %rbx

    lidt idtr(%rip)
    ret

/* 硬件随机数：rdrand，失败重试（需 CPU 支持 RDRAND） */
.global rdrand
rdrand:
1:
    rdrand %eax
    jnc 1b
    ret

/* 时间戳计数器（RDTSC，所有 CPU 支持），返回低 32 位 */
.global rdtsc
rdtsc:
    rdtsc
    ret

/* Console ring critical sections preserve the caller's interrupt state. */
.global irq_save_disable
irq_save_disable:
    pushfq
    pop %rax
    cli
    ret

.global irq_restore
irq_restore:
    push %rdi
    popfq
    ret

/* Development-only exception probe, exposed by the shell `panic` command. */
.global trigger_invalid_opcode
trigger_invalid_opcode:
    ud2
    ret

.global exception_selftest_enabled
exception_selftest_enabled:
    mov $PPOS_EXCEPTION_SELFTEST, %eax
    ret

.global allocator_selftest_enabled
allocator_selftest_enabled:
    mov $PPOS_ALLOCATOR_SELFTEST, %eax
    ret

.global kernel_image_start
kernel_image_start:
    mov $__kernel_start, %rax
    ret

.global kernel_image_end
kernel_image_end:
    mov $__kernel_end, %rax
    ret

.global bootstrap_stack_start
bootstrap_stack_start:
    mov $stack_bottom, %rax
    ret

.global bootstrap_stack_end
bootstrap_stack_end:
    mov $stack_top, %rax
    ret

/* Kernel lives in the 2MiB..4MiB 4KiB page table at physical 0x8000. */
.global protect_kernel_sections
protect_kernel_sections:
    mov $__text_start, %r8
    mov $__text_end, %r9
    mov $__rodata_start, %r10
    mov $__rodata_end, %r11
    xor %ecx, %ecx
1:
    mov %rcx, %rax
    shl $12, %rax
    add $0x200000, %rax
    cmp %r8, %rax
    jb 2f
    cmp %r9, %rax
    jb 3f
2:
    cmp %r10, %rax
    jb 4f
    cmp %r11, %rax
    jb 5f
4:
    movabs $0x8000000000000003, %rdx  /* RW + NX */
    jmp 6f
3:
    mov $0x1, %rdx                    /* text: RO + executable */
    jmp 6f
5:
    movabs $0x8000000000000001, %rdx  /* rodata: RO + NX */
6:
    or %rax, %rdx
    mov %rdx, 0x8000(,%rcx,8)
    inc %ecx
    cmp $512, %ecx
    jne 1b
    mov %cr3, %rax
    mov %rax, %cr3
    mov %cr0, %rax
    bts $16, %rax                     /* supervisor honors read-only PTEs */
    mov %rax, %cr0
    ret

.global kernel_permissions_ok
kernel_permissions_ok:
    mov %cr0, %rax
    bt $16, %rax
    jnc 9f
    mov $0xc0000080, %ecx
    rdmsr
    bt $11, %eax
    jnc 9f
    mov $__text_start, %rax
    sub $0x200000, %rax
    shr $12, %rax
    mov 0x8000(,%rax,8), %rdx
    movabs $0x8000000000000003, %r8
    and %r8, %rdx
    cmp $0x1, %rdx
    jne 9f
    mov $__rodata_start, %rax
    sub $0x200000, %rax
    shr $12, %rax
    mov 0x8000(,%rax,8), %rdx
    and %r8, %rdx
    movabs $0x8000000000000001, %r9
    cmp %r9, %rdx
    jne 9f
    mov $__data_start, %rax
    sub $0x200000, %rax
    shr $12, %rax
    mov 0x8000(,%rax,8), %rdx
    and %r8, %rdx
    cmp %r8, %rdx
    jne 9f
    mov $1, %eax
    ret
9:
    xor %eax, %eax
    ret

.global kernel_stack_alignment_ok
kernel_stack_alignment_ok:
    lea 8(%rsp), %rax
    and $15, %rax
    sete %al
    movzbl %al, %eax
    ret

/* Verify that a software IRQ preserves all GPRs across the asynchronous ABI. */
.global interrupt_register_selftest
interrupt_register_selftest:
    push %rbx
    push %rbp
    push %r12
    push %r13
    push %r14
    push %r15
    mov $1, %rax
    mov $2, %rbx
    mov $3, %rcx
    mov $4, %rdx
    mov $5, %rsi
    mov $6, %rdi
    mov $7, %rbp
    mov $8, %r8
    mov $9, %r9
    mov $10, %r10
    mov $11, %r11
    mov $12, %r12
    mov $13, %r13
    mov $14, %r14
    mov $15, %r15
    int $32
    cmp $1, %rax
    jne 8f
    cmp $2, %rbx
    jne 8f
    cmp $3, %rcx
    jne 8f
    cmp $4, %rdx
    jne 8f
    cmp $5, %rsi
    jne 8f
    cmp $6, %rdi
    jne 8f
    cmp $7, %rbp
    jne 8f
    cmp $8, %r8
    jne 8f
    cmp $9, %r9
    jne 8f
    cmp $10, %r10
    jne 8f
    cmp $11, %r11
    jne 8f
    cmp $12, %r12
    jne 8f
    cmp $13, %r13
    jne 8f
    cmp $14, %r14
    jne 8f
    cmp $15, %r15
    jne 8f
    mov $1, %eax
    jmp 7f
8:
    xor %eax, %eax
7:
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    pop %rbx
    ret

/* Unexpected vectors must not silently return into an unknown state. */
.global isr_default
isr_default:
    cli
1:
    hlt
    jmp 1b

EXC_NOERR 0
EXC_NOERR 1
EXC_NOERR 2
EXC_NOERR 3
EXC_NOERR 4
EXC_NOERR 5
EXC_NOERR 6
EXC_NOERR 7
EXC_ERR   8
EXC_NOERR 9
EXC_ERR   10
EXC_ERR   11
EXC_ERR   12
EXC_ERR   13
EXC_ERR   14
EXC_NOERR 15
EXC_NOERR 16
EXC_ERR   17
EXC_NOERR 18
EXC_NOERR 19
EXC_NOERR 20
EXC_ERR   21
EXC_NOERR 22
EXC_NOERR 23
EXC_NOERR 24
EXC_NOERR 25
EXC_NOERR 26
EXC_NOERR 27
EXC_NOERR 28
EXC_ERR   29
EXC_ERR   30
EXC_NOERR 31

/* Save every GPR. Offsets from frame pointer:
   r15..r8 0..56, rdi 64, rsi 72, rbp 80, rdx 88, rcx 96,
   rbx 104, rax 112, vector 120, error 128, RIP 136. */
exception_common:
    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rbp
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
    mov %rsp, %rdi
    mov %cr2, %rsi
    and $-16, %rsp
    call exception_handler
    cli
1:
    hlt
    jmp 1b

ISR_STUB isr_timer, timer_handler
ISR_STUB isr_keyboard, keyboard_handler

/* ---- 协程上下文切换 ---- */
/* switch_context(old_sp_addr, new_sp)：%rdi=保存旧 rsp 的地址，%rsi=新 rsp */
.global switch_context
switch_context:
    push %rbx
    push %rbp
    push %r12
    push %r13
    push %r14
    push %r15
    mov %rsp, (%rdi)
    mov %rsi, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    pop %rbx
    ret

/* make_context(stack_top, func)：%rdi=栈顶(最高地址)，%rsi=函数地址，返回初始 rsp */
.global make_context
make_context:
    mov %rsi, %rax
    mov %rax, -16(%rdi)     /* return address (saved_rsp + 48) */
    movq $0, -24(%rdi)      /* rbx */
    movq $0, -32(%rdi)      /* rbp */
    movq $0, -40(%rdi)      /* r12 */
    movq $0, -48(%rdi)      /* r13 */
    movq $0, -56(%rdi)      /* r14 */
    movq $0, -64(%rdi)      /* r15 */
    lea -64(%rdi), %rax     /* 初始 rsp（16 字节对齐） */
    ret

.section .data
.align 16
exception_stub_table:
    .quad isr_exc0, isr_exc1, isr_exc2, isr_exc3
    .quad isr_exc4, isr_exc5, isr_exc6, isr_exc7
    .quad isr_exc8, isr_exc9, isr_exc10, isr_exc11
    .quad isr_exc12, isr_exc13, isr_exc14, isr_exc15
    .quad isr_exc16, isr_exc17, isr_exc18, isr_exc19
    .quad isr_exc20, isr_exc21, isr_exc22, isr_exc23
    .quad isr_exc24, isr_exc25, isr_exc26, isr_exc27
    .quad isr_exc28, isr_exc29, isr_exc30, isr_exc31

idtr:
    .word idt_end - idt - 1
    .quad idt

.section .bss
.align 16
.global idt
idt:
    .skip 256 * 16
idt_end:

.section .bss
.align 16
stack_bottom:
    .skip 0x4000
stack_top:

.section .note.GNU-stack,"",@progbits
