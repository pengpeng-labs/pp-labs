/* json.pp：极简 HTTP chunked 解码 + JSON 字符串字段提取（DeepSeek 响应解析用） */

/* 解 HTTP chunked 传输编码：src 指向第一个 chunk 长度行，解码到 dst，返回解码长度；
   若格式非法（非 chunked），返回 -1 */
fn unchunk(src: int, src_len: int, dst: int, dst_cap: int) -> int {
    let di: int = 0;
    let si: int = 0;
    while (si < src_len) {
        /* 读十六进制 chunk 长度（直到 \r 或 ';' 扩展分隔符） */
        let clen: int = 0;
        let c: int = volatile_load8(src + si);
        while (c != 13 && c != 59) {   /* '\r' 或 ';' */
            let d: int = 0;
            if (c >= 48 && c <= 57) {
                d = c - 48;
            } else if (c >= 97 && c <= 102) {
                d = c - 87;
            } else if (c >= 65 && c <= 70) {
                d = c - 55;
            } else {
                return -1;   /* 非十六进制：不是 chunked */
            }
            clen = clen * 16 + d;
            si = si + 1;
            if (si >= src_len) {
                return -1;
            }
            c = volatile_load8(src + si);
        }
        /* 若遇 ';'：跳过 chunk 扩展直到 \r */
        while (c == 59) {
            while (c != 13) {
                si = si + 1;
                if (si >= src_len) {
                    return -1;
                }
                c = volatile_load8(src + si);
            }
        }
        if (si + 2 > src_len) {
            return -1;
        }
        si = si + 2;   /* 跳过 \r\n */
        if (clen == 0) {
            return di;   /* 终止块 */
        }
        let i: int = 0;
        while (i < clen) {
            if (si >= src_len || di >= dst_cap) {
                return -1;
            }
            volatile_store8(dst + di, volatile_load8(src + si));
            di = di + 1;
            si = si + 1;
            i = i + 1;
        }
        if (si + 2 > src_len) { return -1; }
        si = si + 2;   /* 跳过块尾 \r\n */
    }
    return -1;
}

fn writer_write_json_escaped(writer: *BoundedWriter, source: u64, size: int) -> bool {
    let i: int = 0;
    while (i < size && !writer.failed) {
        let c: int = volatile_load8(source + i);
        if (c == 34) {
            writer_write_str(writer, "\\\"");
        } else if (c == 92) {
            writer_write_str(writer, "\\\\");
        } else if (c == 10) {
            writer_write_str(writer, "\\n");
        } else {
            writer_write_byte(writer, c);
        }
        i = i + 1;
    }
    return !writer.failed;
}

fn writer_write_json_cstr(writer: *BoundedWriter, source: u64, max_size: int) -> bool {
    let size: int = 0;
    while (size < max_size && volatile_load8(source + size) != 0) {
        size = size + 1;
    }
    if (size == max_size) {
        writer.failed = true;
        return false;
    }
    return writer_write_json_escaped(writer, source, size);
}

/* 判断 JSON 文本中是否存在 "key": 字段（数组/对象/字符串皆可） */
fn json_has_field(src: int, key: str) -> int {
    let i: int = 0;
    while (volatile_load8(src + i) != 0) {
        if (volatile_load8(src + i) == 34) {   /* '"' */
            let k: int = 0;
            let j: int = i + 1;
            while (key[k] != 0 && volatile_load8(src + j) == key[k]) {
                k = k + 1;
                j = j + 1;
            }
            if (key[k] == 0 && volatile_load8(src + j) == 34) {   /* key 后跟 '"' */
                j = j + 1;
                if (volatile_load8(src + j) == 58) {   /* ':' */
                    return 1;
                }
            }
        }
        i = i + 1;
    }
    return 0;
}

/* 在 JSON 文本中，从 "marker": 之后开始找 "key":" 并提取字符串值，返回长度 */
fn json_find_after(src: int, marker: str, key: str, out: int, out_cap: int) -> int {
    let i: int = 0;
    /* 先找 marker */
    let found: int = 0;
    while (volatile_load8(src + i) != 0) {
        if (volatile_load8(src + i) == 34) {   /* '"' */
            let k: int = 0;
            let j: int = i + 1;
            while (marker[k] != 0 && volatile_load8(src + j) == marker[k]) {
                k = k + 1;
                j = j + 1;
            }
            if (marker[k] == 0 && volatile_load8(src + j) == 34) {   /* marker 后跟 '"' */
                j = j + 1;
                if (volatile_load8(src + j) == 58) {   /* ':' */
                    found = 1;
                    i = j + 1;
                }
            }
        }
        if (found == 1) {
            break;
        }
        i = i + 1;
    }
    if (found == 0) {
        volatile_store8(out, 0);
        return 0;
    }
    /* 从 i 开始找 "key":" */
    return json_find_str(src + i, key, out, out_cap);
}

/* 在 JSON 文本中找 "key":" 并提取字符串值（处理 \n \t \" \\ \r 转义），返回长度 */
fn json_find_str(src: int, key: str, out: int, out_cap: int) -> int {
    if (out_cap <= 0) {
        return -1;
    }
    let i: int = 0;
    while (volatile_load8(src + i) != 0) {
        if (volatile_load8(src + i) == 34) {   /* '"' */
            let k: int = 0;
            let j: int = i + 1;
            while (key[k] != 0 && volatile_load8(src + j) == key[k]) {
                k = k + 1;
                j = j + 1;
            }
            if (key[k] == 0 && volatile_load8(src + j) == 34) {   /* key 后跟 '"' */
                j = j + 1;
                if (volatile_load8(src + j) == 58) {   /* ':' */
                    j = j + 1;
                    if (volatile_load8(src + j) == 34) {   /* '"' */
                        j = j + 1;
                        let o: int = 0;
                        while (true) {
                            let c: int = volatile_load8(src + j);
                            if (o >= out_cap - 1 && c != 34 && c != 0) {
                                volatile_store8(out + out_cap - 1, 0);
                                return -1;
                            }
                            if (c == 92) {   /* '\' 转义 */
                                let e: int = volatile_load8(src + j + 1);
                                if (e == 110) {
                                    volatile_store8(out + o, 10);
                                } else if (e == 116) {
                                    volatile_store8(out + o, 9);
                                } else if (e == 34) {
                                    volatile_store8(out + o, 34);
                                } else if (e == 92) {
                                    volatile_store8(out + o, 92);
                                } else if (e == 114) {
                                    volatile_store8(out + o, 13);
                                } else {
                                    volatile_store8(out + o, e);
                                }
                                o = o + 1;
                                j = j + 2;
                            } else if (c == 34) {   /* 结束 '"' */
                                volatile_store8(out + o, 0);
                                return o;
                            } else if (c == 0) {
                                volatile_store8(out + o, 0);
                                return o;
                            } else {
                                volatile_store8(out + o, c);
                                o = o + 1;
                                j = j + 1;
                            }
                        }
                    }
                }
            }
        }
        i = i + 1;
    }
    volatile_store8(out, 0);
    return 0;
}
