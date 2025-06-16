/* pp-os 32 位启动桩：multiboot v1 头 + 页表 + 长模式转换，最后 far jump 到 64 位内核 */

.section .multiboot, "a"
.align 4
.long 0x1BADB002                       /* magic */
.long 0x00000003                       /* flags: page align + memory info */
.long -(0x1BADB002 + 0x00000003)       /* checksum */

.section .text
.code32
.global _start
_start:
    /* 清零 0x1000..0x9000 用作页表（P4ML + PDPT + 4 个 PD） */
    xor %eax, %eax
    mov $0x1000, %edi
    mov $0x8000, %ecx
    rep stosb

    /* P4ML[0] -> 0x2000 (PDPT) */
    mov $(0x2000 | 3), %eax
    mov %eax, 0x1000

    /* PDPT[0..3] -> 4 个 PD（0x4000/0x5000/0x6000/0x7000），映射 0..4GB */
    mov $(0x4000 | 3), %eax
    mov %eax, 0x2000
    mov $(0x5000 | 3), %eax
    mov %eax, 0x2008
    mov $(0x6000 | 3), %eax
    mov %eax, 0x2010
    mov $(0x7000 | 3), %eax
    mov %eax, 0x2018

    /* PD[0..2047] -> 0..4GB 恒等映射（2MB 页） */
    mov $0x83, %eax
    mov $0x4000, %ebx
    mov $2048, %ecx
ptbl_loop:
    mov %eax, (%ebx)
    add $0x200000, %eax
    add $0x8, %ebx
    dec %ecx
    jnz ptbl_loop

    mov $0x1000, %eax
    mov %eax, %cr3

    lgdt (gdtr64)

    /* PAE */
    mov %cr4, %eax
    bts $5, %eax
    mov %eax, %cr4

    /* LME */
    mov $0xc0000080, %ecx
    rdmsr
    bts $8, %eax
    wrmsr

    /* PG */
    mov %cr0, %eax
    bts $31, %eax
    mov %eax, %cr0

    /* 进入 64 位内核（entry64 固定在 0x200000） */
    ljmp $0x8, $0x200000

.align 16
gdtr64:
    .word gdt64_end - gdt64_begin - 1
    .long gdt64_begin
    .long 0
.align 16
gdt64_begin:
    .long 0x00000000, 0x00000000     /* 0: null */
    .long 0x00000000, 0x00209800     /* 8: code */
    .long 0x00000000, 0x00009000     /* 16: data */
gdt64_end:
