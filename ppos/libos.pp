/* Shared typed contracts between Library OS services and trusted applications. */

struct ServiceBytes {
    data: u64,
    len: int,
    ok: bool,
}

fn service_bytes_empty() -> ServiceBytes {
    let result: ServiceBytes;
    result.data = 0 as u64;
    result.len = 0;
    result.ok = false;
    return result;
}

struct BoundedWriter {
    data: u64,
    len: int,
    cap: int,
    failed: bool,
}

fn writer_new(data: u64, capacity: int) -> BoundedWriter {
    let writer: BoundedWriter;
    writer.data = data;
    writer.len = 0;
    writer.cap = capacity;
    writer.failed = data == (0 as u64) || capacity < 0;
    return writer;
}

fn writer_resume(data: u64, capacity: int, size: int) -> BoundedWriter {
    let writer: BoundedWriter = writer_new(data, capacity);
    if (size < 0 || size > capacity) {
        writer.failed = true;
        return writer;
    }
    writer.len = size;
    return writer;
}

fn writer_can_append(writer: *BoundedWriter, size: int) -> bool {
    if (writer.failed || size < 0 || writer.len > writer.cap - size) {
        writer.failed = true;
        return false;
    }
    return true;
}

fn writer_write_byte(writer: *BoundedWriter, value: int) -> bool {
    if (!writer_can_append(writer, 1)) {
        return false;
    }
    volatile_store8(writer.data + writer.len, value);
    writer.len = writer.len + 1;
    return true;
}

fn writer_write_bytes(writer: *BoundedWriter, source: u64, size: int) -> bool {
    if (!writer_can_append(writer, size)) {
        return false;
    }
    let i: int = 0;
    while (i < size) {
        volatile_store8(writer.data + writer.len + i, volatile_load8(source + i));
        i = i + 1;
    }
    writer.len = writer.len + size;
    return true;
}

fn writer_write_str(writer: *BoundedWriter, value: str) -> bool {
    return writer_write_bytes(writer, ptr_to_int(value), len(value) as int);
}

fn writer_write_cstr(writer: *BoundedWriter, source: u64, max_size: int) -> bool {
    let size: int = 0;
    while (size < max_size && volatile_load8(source + size) != 0) {
        size = size + 1;
    }
    if (size == max_size) {
        writer.failed = true;
        return false;
    }
    return writer_write_bytes(writer, source, size);
}

fn writer_write_uint(writer: *BoundedWriter, value: int) -> bool {
    if (value < 0) {
        return false;
    }
    let digits: [12]u8;
    let count: int = 0;
    if (value == 0) {
        return writer_write_byte(writer, 48);
    }
    while (value > 0) {
        digits[count] = 48 + (value % 10);
        value = value / 10;
        count = count + 1;
    }
    if (!writer_can_append(writer, count)) {
        return false;
    }
    while (count > 0) {
        count = count - 1;
        writer_write_byte(writer, digits[count]);
    }
    return true;
}

fn writer_write_int(writer: *BoundedWriter, value: int) -> bool {
    if (value < 0) {
        if (!writer_write_byte(writer, 45)) {
            return false;
        }
        value = 0 - value;
    }
    return writer_write_uint(writer, value);
}

fn writer_terminate(writer: *BoundedWriter) -> bool {
    if (writer.failed || writer.len >= writer.cap) {
        writer.failed = true;
        return false;
    }
    volatile_store8(writer.data + writer.len, 0);
    return true;
}

fn writer_view(writer: *BoundedWriter) -> ServiceBytes {
    let result: ServiceBytes = service_bytes_empty();
    if (!writer.failed) {
        result.data = writer.data;
        result.len = writer.len;
        result.ok = true;
    }
    return result;
}

fn writer_selftest() -> bool {
    let storage: [5]u8;
    storage[4] = 0xA5;
    let writer: BoundedWriter = writer_new(ptr_to_int(&storage[0]), 4);
    if (!writer_write_str(&writer, "abc") || !writer_terminate(&writer)) {
        return false;
    }
    if (writer_write_str(&writer, "de") || !writer.failed || writer.len != 3) {
        return false;
    }
    return storage[0] == 97 && storage[1] == 98 && storage[2] == 99
        && storage[3] == 0 && storage[4] == 0xA5;
}
