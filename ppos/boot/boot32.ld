/* 32 位 boot 链接脚本：boot 代码在 1M，内嵌 64 位内核二进制在 2M */
ENTRY(_start)

SECTIONS {
    . = 0x100000;

    .multiboot : {
        *(.multiboot)
    }

    .text : {
        *(.text)
    }

    .rodata : {
        *(.rodata)
    }

    .data : {
        *(.data)
    }

    .bss : {
        *(.bss)
    }

    /* 内嵌 64 位内核（raw binary），加载到 0x200000 */
    . = 0x200000;
    .kernel : {
        *(.kernel)
    }
}
