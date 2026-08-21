/* Legacy x86 PIC/PIT/PS2 interrupt mechanisms. */

static tick_count: u64;
static tick_dot: int = 0;
static kb_w: int = 0;
static kb_r: int = 0;

fn pic_remap() {
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20);
    outb(0xA1, 0x28);
    outb(0x21, 0x04);
    outb(0xA1, 0x02);
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    outb(0x21, 0xFC);
    outb(0xA1, 0xFF);
}

fn timer_handler() {
    outb(0x20, 0x20);
    tick_count = tick_count + 1;
    tick_dot = tick_dot + 1;
    if (tick_dot >= 10) {
        console_putc(46);
        tick_dot = 0;
    }
}

fn tick_count_global() -> u64 {
    return tick_count;
}

fn scancode_to_ascii(sc: int) -> int {
    if (sc >= 0x02 && sc <= 0x0B) { return 48 + ((sc - 2 + 9) % 10); }
    if (sc == 0x0C) { return 45; }
    if (sc == 0x0D) { return 61; }
    if (sc == 0x1E) { return 97; }
    if (sc == 0x30) { return 98; }
    if (sc == 0x2E) { return 99; }
    if (sc == 0x20) { return 100; }
    if (sc == 0x12) { return 101; }
    if (sc == 0x21) { return 102; }
    if (sc == 0x22) { return 103; }
    if (sc == 0x23) { return 104; }
    if (sc == 0x17) { return 105; }
    if (sc == 0x24) { return 106; }
    if (sc == 0x25) { return 107; }
    if (sc == 0x26) { return 108; }
    if (sc == 0x32) { return 109; }
    if (sc == 0x31) { return 110; }
    if (sc == 0x18) { return 111; }
    if (sc == 0x19) { return 112; }
    if (sc == 0x10) { return 113; }
    if (sc == 0x13) { return 114; }
    if (sc == 0x1F) { return 115; }
    if (sc == 0x14) { return 116; }
    if (sc == 0x16) { return 117; }
    if (sc == 0x2F) { return 118; }
    if (sc == 0x11) { return 119; }
    if (sc == 0x2D) { return 120; }
    if (sc == 0x15) { return 121; }
    if (sc == 0x2C) { return 122; }
    if (sc == 0x39) { return 32; }
    if (sc == 0x1C) { return 10; }
    if (sc == 0x0E) { return 8; }
    if (sc == 0x34) { return 46; }
    return 0;
}

fn keyboard_handler() {
    let sc: int = inb(0x60);
    if (sc < 128) {
        let c: int = scancode_to_ascii(sc);
        if (c != 0) {
            volatile_store8(0x400000 + kb_w, c);
            kb_w = (kb_w + 1) % 256;
        }
    }
    outb(0x20, 0x20);
}

/* Returns the next ASCII key, or -1 when the IRQ-owned ring is empty. */
fn input_read() -> int {
    if (kb_r == kb_w) {
        return -1;
    }
    let c: int = volatile_load8(0x400000 + kb_r);
    kb_r = (kb_r + 1) % 256;
    return c;
}
