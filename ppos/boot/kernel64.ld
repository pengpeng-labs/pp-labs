/* 64 位内核链接脚本：entry64 固定在 0x200000 */
ENTRY(entry64)

PHDRS {
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS {
    . = 0x200000;
    __kernel_start = .;
    __text_start = .;

    .text : {
        *(.text*)
    } :text
    __text_end = ALIGN(0x1000);

    . = ALIGN(0x1000);
    __rodata_start = .;
    .rodata : {
        *(.rodata*)
        *(.eh_frame*)
    } :rodata
    __rodata_end = ALIGN(0x1000);

    . = ALIGN(0x1000);
    __data_start = .;
    .data : {
        *(.data*)
    } :data

    .bss (NOLOAD) : {
        *(.bss*)
        *(COMMON)
    } :data

    __kernel_end = ALIGN(0x1000);
}
