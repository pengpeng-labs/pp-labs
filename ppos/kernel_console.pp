/* Kernel log source, physical console mirror and panic presentation. */

extern fn irq_save_disable() -> u64;
extern fn irq_restore(flags: u64);

struct KernelLogCursor {
    next: u64,
    lost: u64,
}

static spin_lock_val: int = 0;
static kernel_log_ring: [8192]u8;
static kernel_log_next: u64;
static panic_console_active: int = 0;

fn spin_lock() {
    while (atomic_xchg(ptr_to_int(&spin_lock_val), 1) != 0) {
    }
}

fn spin_unlock() {
    volatile_store32(ptr_to_int(&spin_lock_val), 0);
}

fn physical_console_putc(c: int) {
    outb(0x3F8, c);
}

fn physical_console_write(data: u64, size: int) {
    let i: int = 0;
    while (i < size) {
        physical_console_putc(volatile_load8(data + i));
        i = i + 1;
    }
}

fn kernel_log_append_byte(c: int) {
    let slot: int = (kernel_log_next % (8192 as u64)) as int;
    kernel_log_ring[slot] = c;
    kernel_log_next = kernel_log_next + (1 as u64);
}

fn console_emit_byte(c: int) {
    kernel_log_append_byte(c);
    physical_console_putc(c);
}

fn console_putc(c: int) {
    if (panic_console_active != 0) {
        return;
    }
    let flags: u64 = irq_save_disable();
    spin_lock();
    if (panic_console_active == 0) {
        console_emit_byte(c);
    }
    spin_unlock();
    irq_restore(flags);
}

fn console_write_bytes(data: u64, size: int) {
    if (panic_console_active != 0 || data == (0 as u64) || size <= 0) {
        return;
    }
    let flags: u64 = irq_save_disable();
    spin_lock();
    if (panic_console_active == 0) {
        let i: int = 0;
        while (i < size) {
            console_emit_byte(volatile_load8(data + i));
            i = i + 1;
        }
    }
    spin_unlock();
    irq_restore(flags);
}

fn console_write(s: str) {
    console_write_bytes(ptr_to_int(s), len(s) as int);
}

fn kernel_log_oldest() -> u64 {
    if (kernel_log_next > (8192 as u64)) {
        return kernel_log_next - (8192 as u64);
    }
    return 0 as u64;
}

/* Log Pane input contract: cursors survive wrap and report overwritten bytes. */
fn kernel_log_cursor_oldest() -> KernelLogCursor {
    let cursor: KernelLogCursor;
    cursor.next = kernel_log_oldest();
    cursor.lost = 0 as u64;
    return cursor;
}

fn kernel_log_cursor_tail() -> KernelLogCursor {
    let cursor: KernelLogCursor;
    cursor.next = kernel_log_next;
    cursor.lost = 0 as u64;
    return cursor;
}

fn kernel_log_read(cursor: *KernelLogCursor, destination: u64, capacity: int) -> int {
    if (capacity < 0 || (capacity > 0 && destination == (0 as u64))) {
        return -1;
    }
    let flags: u64 = irq_save_disable();
    spin_lock();
    let oldest: u64 = kernel_log_oldest();
    if (cursor.next < oldest) {
        cursor.lost = cursor.lost + oldest - cursor.next;
        cursor.next = oldest;
    }
    if (cursor.next > kernel_log_next) {
        cursor.next = kernel_log_next;
    }
    let available: u64 = kernel_log_next - cursor.next;
    let count: int = available as int;
    if (count > capacity) {
        count = capacity;
    }
    let i: int = 0;
    while (i < count) {
        let slot: int = ((cursor.next + (i as u64)) % (8192 as u64)) as int;
        volatile_store8(destination + i, kernel_log_ring[slot]);
        i = i + 1;
    }
    cursor.next = cursor.next + (count as u64);
    spin_unlock();
    irq_restore(flags);
    return count;
}

fn kernel_log_reset() {
    kernel_log_next = 0 as u64;
}

fn kernel_log_selftest() -> bool {
    let output: [3]u8;
    kernel_log_reset();
    kernel_log_append_byte(65);
    kernel_log_append_byte(66);
    let cursor: KernelLogCursor = kernel_log_cursor_oldest();
    if (kernel_log_read(&cursor, ptr_to_int(&output[0]), 2) != 2
        || output[0] != 65 || output[1] != 66 || cursor.lost != (0 as u64)) {
        kernel_log_reset();
        return false;
    }
    kernel_log_reset();
    let i: int = 0;
    while (i < 8193) {
        kernel_log_append_byte(i & 255);
        i = i + 1;
    }
    let wrapped: KernelLogCursor;
    wrapped.next = 0 as u64;
    wrapped.lost = 0 as u64;
    let ok: bool = kernel_log_read(&wrapped, ptr_to_int(&output[0]), 1) == 1
        && output[0] == 1 && wrapped.next == (2 as u64)
        && wrapped.lost == (1 as u64);
    kernel_log_reset();
    return ok;
}

/* Compatibility boundary for embedded ppdb modules; ppos code uses console_*. */
fn serial_putc(c: int) {
    console_putc(c);
}

fn serial_print(s: str) {
    console_write(s);
}

fn serial_print_hex64(value: u64) {
    let shift: int = 60;
    while (shift >= 0) {
        let digit: int = ((value >> shift) & (15 as u64)) as int;
        if (digit < 10) {
            console_putc(48 + digit);
        } else {
            console_putc(55 + digit);
        }
        shift = shift - 4;
    }
}

fn panic_console_begin() {
    cli();
    atomic_xchg(ptr_to_int(&panic_console_active), 1);
}

fn panic_console_write(s: str) {
    physical_console_write(ptr_to_int(s), len(s) as int);
}

fn panic_console_hex64(value: u64) {
    let shift: int = 60;
    while (shift >= 0) {
        let digit: int = ((value >> shift) & (15 as u64)) as int;
        if (digit < 10) {
            physical_console_putc(48 + digit);
        } else {
            physical_console_putc(55 + digit);
        }
        shift = shift - 4;
    }
}

fn kernel_panic(message: str) {
    panic_console_begin();
    panic_console_write("\nPPOS PANIC: ");
    panic_console_write(message);
    panic_console_write("\nHALTED\n");
    while (true) {
        hlt();
    }
}

/* Field order is the assembly ABI built by boot64.S: exception_common. */
struct TrapFrame {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
}

fn exception_handler(frame: *TrapFrame, cr2: u64) {
    let address: u64 = ptr_to_int(frame);
    let vector: u64 = volatile_load64(address + 120);
    let error: u64 = volatile_load64(address + 128);
    let rip: u64 = volatile_load64(address + 136);
    panic_console_begin();
    panic_console_write("\nPPOS PANIC: CPU exception\n  vector=0x");
    panic_console_hex64(vector);
    panic_console_write(" error=0x");
    panic_console_hex64(error);
    panic_console_write("\n  rip=0x");
    panic_console_hex64(rip);
    panic_console_write(" cr2=0x");
    panic_console_hex64(cr2);
    panic_console_write("\nHALTED\n");
    while (true) {
        hlt();
    }
}

fn clear_screen() {
    let i: int = 0;
    while (i < 2000) {
        volatile_store16(0xB8000 + 2 * i, 0x0F20);
        i = i + 1;
    }
}
