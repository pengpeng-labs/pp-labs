/* TLS 集成：用 BearSSL 做 HTTPS 客户端（pump loop + 应用数据收发） */

/* BearSSL extern 声明 */
extern fn br_ssl_client_init_full(sc: int, xc: int, ta: int, ta_num: int);
extern fn br_ssl_engine_set_buffer(eng: int, buf: int, len: int, bidi: int);
extern fn br_ssl_engine_inject_entropy(eng: int, data: int, len: int);
extern fn br_ssl_client_reset(sc: int, name: int, resume: int);
extern fn br_ssl_engine_current_state(eng: int) -> int;
extern fn br_ssl_engine_sendrec_buf(eng: int, lenp: int) -> int;
extern fn br_ssl_engine_sendrec_ack(eng: int, len: int);
extern fn br_ssl_engine_recvrec_buf(eng: int, lenp: int) -> int;
extern fn br_ssl_engine_recvrec_ack(eng: int, len: int);
extern fn br_ssl_engine_sendapp_buf(eng: int, lenp: int) -> int;
extern fn br_ssl_engine_sendapp_ack(eng: int, len: int);
extern fn br_ssl_engine_recvapp_buf(eng: int, lenp: int) -> int;
extern fn br_ssl_engine_recvapp_ack(eng: int, len: int);
extern fn br_ssl_engine_flush(eng: int, force: int);
extern fn br_ssl_engine_last_error(eng: int) -> int;
extern fn pp_tls_set_knownkey(sc: int);
extern fn pp_tls_last_error(sc: int) -> int;
extern fn rdtsc() -> int;

/* 固定内存布局 */
static TLS_SC: int = 0x660000;      /* br_ssl_client_context (3720B) */
static TLS_XC: int = 0x661000;      /* br_x509_minimal_context (3168B) */
static TLS_RNG: int = 0x662000;     /* br_hmac_drbg_context (144B) */
static TLS_SEED: int = 0x662100;    /* 熵种子 (32B) */
static TLS_BUF: int = 0x663000;     /* BR_SSL_BUFSIZE_BIDI (33178B) */
static TLS_LENP: int = 0x66F000;    /* len 指针暂存 */
static TLS_RESP: int = 0x670000;    /* HTTPS 响应缓冲 */

/* 引擎 = sc + 0（第一个成员） */

fn tls_init(host: str) {
    /* 重置分块喂食状态（上一轮可能残留）——tls_rx_seq 由 tcp_connect 设置，勿清 */
    rx_plen = 0;
    rx_poff = 0;
    app_stage = 0;
    tls_fin = 0;
    rx_flush();   /* 丢弃上一连接残留帧 */
    br_ssl_client_init_full(TLS_SC, TLS_XC, 0, 0);
    br_ssl_engine_set_buffer(TLS_SC, TLS_BUF, 33178, 1);
    let i: int = 0;
    let s: int = rdtsc();
    s = s ^ 0x9E3779B9;
    while (i < 8) {
        s = s ^ (s << 13);
        s = s ^ (s >> 17);
        s = s ^ (s << 5);
        volatile_store32(TLS_SEED + i * 4, s);
        i = i + 1;
    }
    br_ssl_engine_inject_entropy(TLS_SC, TLS_SEED, 32);
    pp_tls_set_knownkey(TLS_SC);
    br_ssl_client_reset(TLS_SC, ptr_to_int(host), 0);
}

/* 泵循环：处理引擎发送/接收，直到 done_mask 满足且无待发数据。
   每次迭代 hlt 让出（约 10ms），guard 8000 = 约 80 秒超时
   CLOSED：不立即返回——先排空 SENDREC/RECVREC（服务器 Connection: close 时
   数据记录与 close_notify 同批到达，直接退出会丢尾部数据） */
fn tls_pump(dst_ip: int, dst_port: int, done_mask: int) -> int {
    let guard: int = 0;
    let closed: int = 0;
    while (guard < 8000) {
        guard = guard + 1;
        /* RTO 重传检查（uIP 精华）——暂禁用定位问题 */
        /* if (tcp_retransmit() == 1) {
            return 1;
        } */
        let st: int = br_ssl_engine_current_state(TLS_SC);
        if ((st & 1) != 0) {
            closed = 1;
        }
        let busy: int = 0;
        if ((st & 2) != 0) {
            let buf: int = br_ssl_engine_sendrec_buf(TLS_SC, TLS_LENP);
            let len: int = volatile_load32(TLS_LENP);
            if (len > 0) {
                tcp_send_data(dst_ip, dst_port, buf, len);
                br_ssl_engine_sendrec_ack(TLS_SC, len);
                busy = 1;
            }
        }
        if ((st & 4) != 0) {
            let buf: int = br_ssl_engine_recvrec_buf(TLS_SC, TLS_LENP);
            let cap: int = volatile_load32(TLS_LENP);
            let n: int = tcp_recv_tls(buf, cap);
            if (n > 0) {
                br_ssl_engine_recvrec_ack(TLS_SC, n);
                busy = 1;
            }
        }
        if (closed == 1) {
            /* 关闭后：等引擎处理完当前数据（close_notify 在最后，此前记录已全部入引擎） */
            if (busy == 0) {
                serial_print("tls closed err=");
                print_int(pp_tls_last_error(TLS_SC));
                serial_putc(10);
                return 1;
            }
            hlt();
            continue;
        }
        if (tls_fin == 1) {
            /* TCP FIN：数据已全部到达（Connection: close 无 close_notify） */
            if (busy == 0) {
                serial_print("tls fin done\n");
                return 1;
            }
            hlt();
            continue;
        }
        if ((st & done_mask) != 0) {
            if ((st & 2) == 0) {
                return 0;
            }
        }
        hlt();
    }
    serial_print("tls pump timeout\n");
    return 1;
}

/* 清空 RX 环残留帧（握手重传等；丢了的数据服务器会重传） */
fn rx_flush() {
    let i: int = 0;
    let p: int = 0x610000;
    while (i < 64) {
        if (e1000_recv(p) <= 0) {
            return;
        }
        i = i + 1;
    }
}

/* 发送应用数据（HTTP 请求）并经 TLS 加密送出 */
fn tls_send(dst_ip: int, dst_port: int, data: int, len: int) {
    let buf: int = br_ssl_engine_sendapp_buf(TLS_SC, TLS_LENP);
    let cap: int = volatile_load32(TLS_LENP);
    let n: int = len;
    if (n > cap) {
        n = cap;
    }
    let i: int = 0;
    while (i < n) {
        volatile_store8(buf + i, volatile_load8(data + i));
        i = i + 1;
    }
    br_ssl_engine_sendapp_ack(TLS_SC, n);
    /* 立即 flush：把明文加密成记录并放入发送缓冲（否则数据滞留不发出） */
    br_ssl_engine_flush(TLS_SC, 1);
    /* 泵直到发送完成（SENDAPP 且无 SENDREC） */
    let r: int = tls_pump(dst_ip, dst_port, 8);
}

/* 接收应用数据（HTTPS 响应），返回长度。
   即使连接已关闭（服务器 Connection: close），也要读空 recvapp 残留数据 */
fn tls_recv(dst_ip: int, dst_port: int, buf: int, cap: int) -> int {
    let r: int = tls_pump(dst_ip, dst_port, 16);
    let abuf: int = br_ssl_engine_recvapp_buf(TLS_SC, TLS_LENP);
    let len: int = volatile_load32(TLS_LENP);
    if (len > cap) {
        len = cap;
    }
    let i: int = 0;
    while (i < len) {
        volatile_store8(buf + i, volatile_load8(abuf + i));
        i = i + 1;
    }
    br_ssl_engine_recvapp_ack(TLS_SC, len);
    if (len == 0) {
        return 0;
    }
    return len;
}

/* TCP 连接（三次握手），成功后 tcp_state=2 */
fn tcp_connect(dst_ip: int, dst_port: int) -> int {
    tcp_src = tcp_src + 1;   /* 换源端口：避免与上一连接（slirp 残留）冲突 */
    tcp_seq = 0x1000;
    tcp_state = 1;
    tcp_send(dst_ip, dst_port, 0x02, tcp_seq, 0, 0, 0);
    let t: int = 0;
    while (t < 3000 && tcp_state == 1) {
        net_poll();
        hlt();
        t = t + 1;
    }
    if (tcp_state == 1) {
        serial_print("no synack\n");
        return 1;
    }
    serial_print("tcp connected\n");
    return 0;
}

/* TCP 发送数据（PSH+ACK，推进 seq；记录重传信息供 RTO 重发） */
fn tcp_send_data(dst_ip: int, dst_port: int, payload: int, payload_len: int) {
    tcp_send(dst_ip, dst_port, 0x18, tcp_seq, tcp_ack, payload, payload_len);
    tcp_seq = tcp_seq + payload_len;
    /* 记录副本（仅在有意义长度内；TLS 握手/请求 ≤ 1024） */
    let i: int = 0;
    while (i < payload_len && i < 1024) {
        tcp_rexmit_buf[i] = volatile_load8(payload + i);
        i = i + 1;
    }
    tcp_rexmit_len = i;
    let j: int = 0;
    while (j < 4) {
        tcp_rexmit_dst[j] = volatile_load8(dst_ip + j);
        j = j + 1;
    }
    tcp_rexmit_port = dst_port;
    tcp_rexmit_flags = 0x18;
    tcp_outstanding = 1;
    tcp_retry_n = 0;
    tcp_retry_timer = 100;   /* 初始 RTO ≈ 1s（PIT 100Hz） */
}

/* RTO 重传检查（uIP 精华：定时器递减 + 指数退避 + 超限放弃）
   每次 pump 迭代调用；返回 1 表示连接已放弃（超限） */
fn tcp_retransmit() -> int {
    if (tcp_outstanding == 0) {
        return 0;
    }
    tcp_retry_timer = tcp_retry_timer - 1;
    if (tcp_retry_timer > 0) {
        return 0;
    }
    if (tcp_retry_n >= 5) {
        /* 重传超限：放弃连接 */
        serial_print("tcp rexmit giveup\n");
        tcp_outstanding = 0;
        tcp_state = 0;
        return 1;
    }
    /* 指数退避：1s/2s/4s/8s/16s */
    tcp_retry_n = tcp_retry_n + 1;
    tcp_retry_timer = 100 << (tcp_retry_n - 1);
    if (tcp_retry_timer > 1600) {
        tcp_retry_timer = 1600;
    }
    serial_print("tcp rexmit #");
    print_int(tcp_retry_n);
    serial_putc(10);
    /* 重发：seq 回退到副本起点 */
    tcp_seq = tcp_seq - tcp_rexmit_len;
    tcp_send(ptr_to_int(&tcp_rexmit_dst[0]), tcp_rexmit_port, tcp_rexmit_flags, tcp_seq, tcp_ack,
        ptr_to_int(&tcp_rexmit_buf[0]), tcp_rexmit_len);
    tcp_seq = tcp_seq + tcp_rexmit_len;
    return 0;
}

/* TCP 接收 TLS 数据，拷到 buf，返回长度（跨调用跟踪当前帧的剩余字节） */
static rx_plen: int = 0;   /* 当前帧 TCP payload 剩余字节 */
static rx_poff: int = 0;   /* 当前帧 payload 已读偏移 */
static rx_ni2: int = 0;    /* 当前帧所在 RX 描述符索引 */
static rx_base: int = 0;   /* 当前帧 payload 起始偏移（14+20+doff） */
static app_stage: int = 0; /* 1 = 应用阶段：丢弃握手/CCS 残留记录 */
static tls_rx_seq: int = -1;   /* 期望的下一个数据 seq（-1 = 未建立） */
static tls_fin: int = 0;       /* 收到 TCP FIN（服务器关闭） */

fn tcp_recv_tls(buf: int, cap: int) -> int {
    if (rx_plen <= 0) {
        let p: int = 0x610000;
        let len: int = e1000_recv(p);
        if (len <= 0) {
            return 0;
        }
        if (volatile_load8(p + 12) != 0x08) {
            return 0;
        }
        if (volatile_load8(p + 13) != 0x00) {
            return 0;
        }
        if (volatile_load8(p + 23) != 6) {
            return 0;
        }
        if ((volatile_load8(p + 47) & 0x02) != 0) {
            return 0;   /* 残留 SYN/SYNACK 帧（重传），不是 TLS 数据 */
        }
        /* ACK 确认我们发送的数据（uIP UIP_ACKDATA）——先于 seq 校验：
           ACK-only 帧（plen=0）seq 是服务器发送 seq，不参与数据连续性校验 */
        if ((volatile_load8(p + 47) & 0x10) != 0) {
            let their_ack: int = load_be32(p + 42);
            if (tcp_outstanding == 1 && their_ack >= tcp_seq) {
                tcp_outstanding = 0;
                tcp_retry_n = 0;
            }
        }
        /* TCP data offset（p+46 高 4 位 × 4），真实 payload 起点 = 14+20+doff */
        let doff: int = (volatile_load8(p + 46) >> 4) * 4;
        let plen: int = load_be16(p + 16) - 20 - doff;
        if (plen <= 0) {
            return 0;   /* 纯 ACK 帧（无数据） */
        }
        /* 数据帧的 seq 连续性校验：丢弃旧连接残留帧/重传帧 */
        let fseq: int = load_be32(p + 38);
        if (tls_rx_seq >= 0) {
            if (fseq != tls_rx_seq) {
                /* uIP 精华：seq 不符回纯 ACK（告知对端期望 seq），而非静默丢弃 */
                tcp_send_ack(p);
                return 0;
            }
        }
        /* TCP FIN：服务器关闭（HTTP/1.1 Connection: close 直接 FIN，无 TLS close_notify） */
        if ((volatile_load8(p + 47) & 0x01) != 0) {
            tls_fin = 1;
            serial_print("tcp fin\n");
        }
        serial_print("rx: doff=");
        print_int(doff);
        serial_print(" plen=");
        print_int(plen);
        serial_print(" flags=");
        print_byte_hex(volatile_load8(p + 47));
        serial_print(" seq=");
        print_int(load_be32(p + 38));
        serial_putc(10);
        if (app_stage == 1) {
            let rtype: int = volatile_load8(rx_buf + rx_tail * 2048 + 14 + 20 + doff);
            serial_print("  rtype=");
            print_byte_hex(rtype);
            serial_putc(10);
            if (rtype != 23 && rtype != 21) {
                /* 握手(22)/CCS(20) 残留记录：丢弃整帧（帧已被 e1000_recv 消费） */
                return 0;
            }
        }
        rx_plen = plen;
        rx_poff = 0;
        rx_ni2 = rx_tail;
        rx_base = 14 + 20 + doff;
        tcp_ack = load_be32(p + 38);
        tls_rx_seq = fseq + plen;   /* 下一帧期望 seq */
    }
    let n: int = rx_plen;
    if (n > cap) {
        n = cap;
    }
    let i: int = 0;
    while (i < n) {
        volatile_store8(buf + i, volatile_load8(rx_buf + rx_ni2 * 2048 + rx_base + rx_poff + i));
        i = i + 1;
    }
    rx_poff = rx_poff + n;
    rx_plen = rx_plen - n;
    tcp_ack = tcp_ack + n;
    tcp_send_ack(0x610000);
    return n;
}

/* 把 str 追加到 req 缓冲 */
fn req_append(req: int, ri: int, s: str) -> int {
    let i: int = 0;
    while (s[i] != 0) {
        volatile_store8(req + ri, s[i]);
        ri = ri + 1;
        i = i + 1;
    }
    return ri;
}

/* HTTPS GET：TCP 连接 + TLS 握手 + GET 请求 + 收响应 */
fn https_get(dst_ip: int, dst_port: int, host: str, path: str) {
    if (tcp_connect(dst_ip, dst_port) != 0) {
        return;
    }
    tls_init(host);
    let r: int = tls_pump(dst_ip, dst_port, 8);
    if (r != 0) {
        serial_print("tls handshake fail\n");
        return;
    }
    rx_flush();   /* 丢弃握手飞行重传残留 */
    app_stage = 1;
    /* 构建 GET 请求 */
    let req: int = 0x66E000;
    let ri: int = 0;
    ri = req_append(req, ri, "GET ");
    ri = req_append(req, ri, path);
    ri = req_append(req, ri, " HTTP/1.1\r\nHost: ");
    ri = req_append(req, ri, host);
    ri = req_append(req, ri, "\r\nConnection: close\r\n\r\n");
    tls_send(dst_ip, dst_port, req, ri);
    serial_print("https sent\n");
    /* 收响应 */
    let resp_len: int = 0;
    let guard: int = 0;
    while (guard < 200) {
        guard = guard + 1;
        let n: int = tls_recv(dst_ip, dst_port, TLS_RESP + resp_len, 4096 - resp_len);
        if (n <= 0) {
            break;
        }
        resp_len = resp_len + n;
    }
    if (resp_len > 0) {
        serial_print("HTTPS response (");
        print_int(resp_len);
        serial_print(" bytes):\n");
        let j: int = 0;
        while (j < resp_len && j < 600) {
            serial_putc(volatile_load8(TLS_RESP + j));
            j = j + 1;
        }
        serial_putc(10);
    } else {
        serial_print("no https response\n");
    }
}

/* 数字转字符串写入 buf（十进制），返回长度 */
fn itoa_buf(n: int, buf: int) -> int {
    let tmp: [u8; 12];
    let i: int = 0;
    if (n == 0) {
        volatile_store8(buf, 48);
        return 1;
    }
    while (n > 0) {
        tmp[i] = 48 + (n % 10);
        n = n / 10;
        i = i + 1;
    }
    let len: int = i;
    let j: int = 0;
    while (i > 0) {
        i = i - 1;
        volatile_store8(buf + j, tmp[i]);
        j = j + 1;
    }
    return len;
}

/* DeepSeek API key：从 0x400600 读取（由 ds 命令从文件系统 "key" 文件载入） */
fn api_key_str() -> str {
    return int_to_ptr(0x400600);
}

/* HTTPS POST：连接 + 握手 + POST（JSON body + Bearer 认证）+ 收响应；返回明文响应长度（存于 TLS_RESP） */
fn https_post(dst_ip: int, dst_port: int, host: str, path: str, body: int, body_len: int) -> int {
    if (tcp_connect(dst_ip, dst_port) != 0) {
        return 0;
    }
    tls_init(host);
    let r: int = tls_pump(dst_ip, dst_port, 8);
    if (r != 0) {
        serial_print("tls handshake fail\n");
        return 0;
    }
    rx_flush();   /* 丢弃握手飞行重传残留 */
    app_stage = 1;
    /* 构建 POST 请求 */
    let req: int = 0x66E000;
    let ri: int = 0;
    ri = req_append(req, ri, "POST ");
    ri = req_append(req, ri, path);
    ri = req_append(req, ri, " HTTP/1.1\r\nHost: ");
    ri = req_append(req, ri, host);
    ri = req_append(req, ri, "\r\nAuthorization: Bearer ");
    ri = req_append(req, ri, api_key_str());
    ri = req_append(req, ri, "\r\nContent-Type: application/json\r\nContent-Length: ");
    ri = ri + itoa_buf(body_len, req + ri);
    ri = req_append(req, ri, "\r\nConnection: close\r\n\r\n");
    let i: int = 0;
    while (i < body_len) {
        volatile_store8(req + ri, volatile_load8(body + i));
        ri = ri + 1;
        i = i + 1;
    }
    tls_send(dst_ip, dst_port, req, ri);
    serial_print("https post sent\n");
    /* 收响应 */
    let resp_len: int = 0;
    let guard: int = 0;
    while (guard < 200) {
        guard = guard + 1;
        let n: int = tls_recv(dst_ip, dst_port, TLS_RESP + resp_len, 4096 - resp_len);
        if (n <= 0) {
            break;
        }
        resp_len = resp_len + n;
    }
    if (resp_len > 0) {
        serial_print("HTTPS response (");
        print_int(resp_len);
        serial_print(" bytes)\n");
        let j: int = 0;
        while (j < resp_len && j < 700) {
            serial_putc(volatile_load8(TLS_RESP + j));
            j = j + 1;
        }
        serial_putc(10);
    } else {
        serial_print("no https response\n");
    }
    return resp_len;
}
