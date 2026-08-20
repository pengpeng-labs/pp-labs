/* browser.pp：HTML → 纯文本 + 网页抓取（库层：app 可复用） */

static web_body_len: int = 0;   /* 最近一次抓取的 body 长度 */

/* 抓取网页：host 为 "host[:port]" 字符串，返回 body 在 0x650000 的偏移（0 表示失败）；
   流程：端口解析 → IP 直解/DNS → ARP → HTTP GET → 定位 body */
fn web_fetch(host: str) -> int {
    let port: int = 80;
    let pj: int = 0;
    while (volatile_load8(ptr_to_int(host + pj)) != 0 && volatile_load8(ptr_to_int(host + pj)) != 58) {
        pj = pj + 1;
    }
    if (volatile_load8(ptr_to_int(host + pj)) == 58) {
        port = 0;
        pj = pj + 1;
        while (volatile_load8(ptr_to_int(host + pj)) >= 48 && volatile_load8(ptr_to_int(host + pj)) <= 57) {
            port = port * 10 + (volatile_load8(ptr_to_int(host + pj)) - 48);
            pj = pj + 1;
        }
    }
    /* IP：数字开头直解，否则 DNS */
    let ip: [4]u8;
    ip[0] = 0;
    ip[1] = 0;
    ip[2] = 0;
    ip[3] = 0;
    let hc: int = volatile_load8(ptr_to_int(host));
    if (hc >= 48 && hc <= 57) {
        let part: int = 0;
        let oc: int = 0;
        let hi: int = 0;
        while (true) {
            let c: int = volatile_load8(ptr_to_int(host + hi));
            if (c >= 48 && c <= 57) {
                part = part * 10 + (c - 48);
            } else if (c == 46) {
                ip[oc] = part & 0xFF;
                oc = oc + 1;
                part = 0;
            } else {
                break;
            }
            hi = hi + 1;
        }
        ip[oc] = part & 0xFF;
    } else {
        dns_query(host);
        let ht2: int = 0;
        while (ht2 < 5000) {
            if (net_poll() == 1) {
                ht2 = 5000;
            } else {
                ht2 = ht2 + 1;
            }
            hlt();
        }
        ip[0] = dns_resolved[0];
        ip[1] = dns_resolved[1];
        ip[2] = dns_resolved[2];
        ip[3] = dns_resolved[3];
    }
    /* ARP 网关（解析 gateway_mac） */
    let gw: [4]u8;
    gw[0] = 10;
    gw[1] = 0;
    gw[2] = 2;
    gw[3] = 2;
    arp_request(ptr_to_int(&gw[0]));
    let ht: int = 0;
    while (ht < 3000) {
        if (net_poll() == 1) {
            ht = 3000;
        } else {
            ht = ht + 1;
        }
        hlt();
    }
    /* HTTP GET / */
    let rl: int = http_get_host(ptr_to_int(&ip[0]), port, host, "/");
    if (rl <= 0) {
        return 0;
    }
    /* 定位 body（\r\n\r\n 之后） */
    let hi: int = 0;
    while (hi < rl - 3) {
        if (volatile_load8(0x650000 + hi) == 13
            && volatile_load8(0x650000 + hi + 1) == 10
            && volatile_load8(0x650000 + hi + 2) == 13
            && volatile_load8(0x650000 + hi + 3) == 10) {
            break;
        }
        hi = hi + 1;
    }
    let body_off: int = hi + 4;
    let blen: int = rl - body_off;
    if (blen < 0) {
        blen = 0;
    }
    web_body_len = blen;
    return body_off;
}

/* 比较 src[i..] 与实体名 name，长度 n；匹配返回 1 */
fn ent_match(src: int, i: int, name: str, n: int) -> int {
    let k: int = 0;
    while (k < n) {
        if (volatile_load8(src + i + k) != name[k]) {
            return 0;
        }
        k = k + 1;
    }
    if (volatile_load8(src + i + n) != 59) {   /* ';' */
        return 0;
    }
    return 1;
}

/* 比较 src[i..] 与字面量 s 是否相等（到非字母字符或 s 结束） */
fn tag_eq(src: int, i: int, s: str) -> int {
    let k: int = 0;
    while (s[k] != 0) {
        let c: int = volatile_load8(src + i + k);
        if (c >= 65 && c <= 90) {
            c = c + 32;   /* 大写转小写 */
        }
        if (c != s[k]) {
            return 0;
        }
        k = k + 1;
    }
    let nx: int = volatile_load8(src + i + k);
    if ((nx >= 97 && nx <= 122) || (nx >= 65 && nx <= 90)) {
        return 0;   /* 标签名更长（如 h1 vs h） */
    }
    return 1;
}

/* 把 HTML 转换为纯文本写入 dst，返回长度（标签跳过、实体解码、块级标签换行） */
fn html_to_text(src: int, slen: int, dst: int) -> int {
    let i: int = 0;
    let o: int = 0;
    while (i < slen) {
        let c: int = volatile_load8(src + i);
        if (c == 60) {   /* '<'：标签 */
            let t: int = i + 1;
            if (volatile_load8(src + t) == 33) {   /* <!-- 注释 */
                while (i < slen - 2) {
                    if (volatile_load8(src + i) == 45
                        && volatile_load8(src + i + 1) == 45
                        && volatile_load8(src + i + 2) == 62) {
                        i = i + 3;
                        t = i;
                        break;
                    }
                    i = i + 1;
                }
                i = t;
            } else {
                /* script/style：跳过内容直到闭合标签 */
                if (tag_eq(src, t, "script") == 1 || tag_eq(src, t, "style") == 1) {
                    let close: int = 0;
                    while (i < slen - 8) {
                        if (volatile_load8(src + i) == 60
                            && volatile_load8(src + i + 1) == 47) {   /* '</' */
                            if (tag_eq(src, i + 2, "script") == 1 || tag_eq(src, i + 2, "style") == 1) {
                                close = i;
                                break;
                            }
                        }
                        i = i + 1;
                    }
                    if (close != 0) {
                        i = close;
                    } else {
                        i = slen;
                    }
                } else {
                    /* 普通标签：跳过到 '>'，块级标签输出换行 */
                    let blk: int = 0;
                    if (tag_eq(src, t, "br") == 1 || tag_eq(src, t, "p") == 1
                        || tag_eq(src, t, "div") == 1 || tag_eq(src, t, "h1") == 1
                        || tag_eq(src, t, "h2") == 1 || tag_eq(src, t, "h3") == 1
                        || tag_eq(src, t, "h4") == 1 || tag_eq(src, t, "h5") == 1
                        || tag_eq(src, t, "h6") == 1 || tag_eq(src, t, "li") == 1
                        || tag_eq(src, t, "tr") == 1 || tag_eq(src, t, "table") == 1) {
                        blk = 1;
                    }
                    while (i < slen && volatile_load8(src + i) != 62) {
                        i = i + 1;
                    }
                    i = i + 1;   /* 跳过 '>' */
                    if (blk == 1 && o > 0 && volatile_load8(dst + o - 1) != 10) {
                        volatile_store8(dst + o, 10);
                        o = o + 1;
                    }
                }
            }
        } else if (c == 38) {   /* '&'：实体解码 */
            if (ent_match(src, i + 1, "amp", 3) == 1) {
                volatile_store8(dst + o, 38);
                o = o + 1;
                i = i + 5;
            } else if (ent_match(src, i + 1, "lt", 2) == 1) {
                volatile_store8(dst + o, 60);
                o = o + 1;
                i = i + 4;
            } else if (ent_match(src, i + 1, "gt", 2) == 1) {
                volatile_store8(dst + o, 62);
                o = o + 1;
                i = i + 4;
            } else if (ent_match(src, i + 1, "quot", 4) == 1) {
                volatile_store8(dst + o, 34);
                o = o + 1;
                i = i + 6;
            } else if (ent_match(src, i + 1, "apos", 4) == 1) {
                volatile_store8(dst + o, 39);
                o = o + 1;
                i = i + 6;
            } else if (ent_match(src, i + 1, "nbsp", 4) == 1) {
                volatile_store8(dst + o, 32);
                o = o + 1;
                i = i + 6;
            } else if (volatile_load8(src + i + 1) == 35) {   /* '#'：数字实体 &#NN; */
                let num: int = 0;
                let j: int = i + 2;
                let ok: int = 1;
                while (volatile_load8(src + j) != 59) {
                    let d: int = volatile_load8(src + j);
                    if (d >= 48 && d <= 57) {
                        num = num * 10 + (d - 48);
                    } else {
                        ok = 0;
                        j = slen;
                    }
                    j = j + 1;
                    if (j >= slen) {
                        ok = 0;
                        j = slen;
                    }
                }
                if (ok == 1 && num != 0) {
                    volatile_store8(dst + o, num & 0xFF);
                    o = o + 1;
                }
                i = j + 1;
            } else {
                volatile_store8(dst + o, 38);
                o = o + 1;
                i = i + 1;
            }
        } else {
            volatile_store8(dst + o, c);
            o = o + 1;
            i = i + 1;
        }
    }
    volatile_store8(dst + o, 0);
    return o;
}
