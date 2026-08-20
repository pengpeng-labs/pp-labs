fn strlen(s: str) -> int {
    return len(s) as int;
}

fn strcmp(a: str, b: str) -> int {
    let i: int = 0;
    let an: int = len(a) as int;
    let bn: int = len(b) as int;
    while (i < an && i < bn) {
        let ca: int = a[i];
        let cb: int = b[i];
        if (ca != cb) {
            return ca - cb;
        }
        i = i + 1;
    }
    return an - bn;
}

/* 拷贝切片的全部字节，返回写入长度；调用方负责容量和终止符。 */
fn str_copy(dst: *u8, src: str) -> int {
    let n: int = len(src) as int;
    let i: int = 0;
    while (i < n) {
        dst[i] = src[i];
        i = i + 1;
    }
    return n;
}

/* C 字符串边界 helper，仅用于 FFI；普通 str 代码应使用 len(s)。 */
fn cstr_len(src: *u8) -> int {
    let n: int = 0;
    while (src[n] != 0) {
        n = n + 1;
    }
    return n;
}
