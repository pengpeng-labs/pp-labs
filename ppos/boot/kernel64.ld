/* 64 位内核链接脚本：entry64 固定在 0x200000 */
ENTRY(entry64)

SECTIONS {
    . = 0x200000;

    .text : {
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    .data : {
        *(.data)
    }

    .bss : {
        *(.bss)
    }
}
