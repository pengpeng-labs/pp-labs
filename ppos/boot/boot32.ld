/* 32 位 boot 链接脚本：boot 代码在 1M，内嵌 64 位内核二进制在 2M */
ENTRY(_start)

PHDRS {
    boot_text PT_LOAD FLAGS(5);
    boot_data PT_LOAD FLAGS(6);
    kernel PT_LOAD FLAGS(5);
}

SECTIONS {
    . = 0x100000;

    .multiboot : {
        *(.multiboot)
    } :boot_text

    .text : {
        *(.text)
    } :boot_text

    .rodata : {
        *(.rodata)
    } :boot_text

    .data : {
        *(.data)
    } :boot_data

    .bss : {
        *(.bss)
    } :boot_data

    /* 内嵌 64 位内核（raw binary），加载到 0x200000 */
    . = 0x200000;
    .kernel : {
        *(.kernel)
    } :kernel
}
