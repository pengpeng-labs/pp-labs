fn main() -> int {
    volatile_store16(0xB8000, 0x0F48);
    volatile_store8(0xB8000, 72);
    return 0;
}
