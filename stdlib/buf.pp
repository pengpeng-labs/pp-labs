/* 可增长字节缓冲。Buf 拥有 data，调用方必须 buf_free。 */

import "alloc.pp";

struct Buf {
    data: *u8,
    len: int,
    cap: int,
}

fn buf_new(initial_cap: int) -> Buf {
    if (initial_cap < 8) {
        initial_cap = 8;
    }
    let data: *u8 = alloc(initial_cap);
    if (data == 0) {
        return Buf { data: data, len: 0, cap: 0 };
    }
    return Buf { data: data, len: 0, cap: initial_cap };
}

fn buf_reserve(buf: *Buf, needed: int) -> bool {
    if (needed <= buf.cap) {
        return true;
    }
    let next_cap: int = buf.cap;
    if (next_cap < 8) {
        next_cap = 8;
    }
    while (next_cap < needed) {
        next_cap = next_cap * 2;
    }
    let next: *u8 = alloc(next_cap);
    if (next == 0) {
        return false;
    }
    let i: int = 0;
    while (i < buf.len) {
        next[i] = buf.data[i];
        i = i + 1;
    }
    if (buf.data != 0) {
        dealloc(buf.data);
    }
    buf.data = next;
    buf.cap = next_cap;
    return true;
}

fn buf_push(buf: *Buf, value: u8) -> bool {
    if (buf_reserve(buf, buf.len + 1) == false) {
        return false;
    }
    buf.data[buf.len] = value;
    buf.len = buf.len + 1;
    return true;
}

fn buf_append(buf: *Buf, value: str) -> bool {
    let n: int = len(value) as int;
    if (buf_reserve(buf, buf.len + n) == false) {
        return false;
    }
    let i: int = 0;
    while (i < n) {
        buf.data[buf.len + i] = value[i];
        i = i + 1;
    }
    buf.len = buf.len + n;
    return true;
}

fn buf_view(buf: *Buf) -> str {
    return str_from_ptr(buf.data, buf.len);
}

fn buf_clear(buf: *Buf) {
    buf.len = 0;
}

fn buf_free(buf: *Buf) {
    if (buf.data != 0) {
        dealloc(buf.data);
    }
    buf.data = 0 as *u8;
    buf.len = 0;
    buf.cap = 0;
}
