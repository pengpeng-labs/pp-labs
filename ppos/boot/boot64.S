/* pp-os 64 位入口 + IDT（运行时构建）+ 中断桩 */

/* 中断桩：保存 caller-saved 寄存器 → 调处理器 → 恢复 → iretq */
.macro ISR_STUB name, handler
.global \name
\name:
    push %rax
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    call \handler
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rdx
    pop %rcx
    pop %rax
    iretq
.endm

.section .text
.code64
.global entry64
entry64:
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

    call load_idt
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

/* 默认处理器：忽略 */
.global isr_default
isr_default:
    iretq

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
