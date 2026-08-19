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

/* uIP glue（libuip.a 链接） */
extern fn uip_glue_init();
extern fn uip_glue_connect(ip: u64, port: int) -> int;
extern fn uip_glue_send(buf: u64, len: int) -> int;
extern fn uip_glue_recv(buf: u64, cap: int) -> int;
extern fn uip_glue_poll() -> int;
extern fn uip_glue_closed() -> int;
extern fn uip_glue_connected() -> int;
extern fn uip_glue_timedout() -> int;
extern fn uip_glue_dns_send(buf: u64, len: int) -> int;

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
   每次迭代：uip_glue_poll（收帧/重传驱动）+ 引擎数据交换
   guard 8000 = 约 80 秒超时（每轮含 10ms 让出） */
fn tls_pump(dst_ip: int, dst_port: int, done_mask: int) -> int {
    let guard: int = 0;
    let closed: int = 0;
    while (guard < 8000) {
        guard = guard + 1;
        /* uIP 驱动：收帧 + 周期（重传/超时由 uIP 处理） */
        uip_glue_poll();
        let st: int = br_ssl_engine_current_state(TLS_SC);
        if ((st & 1) != 0) {
            closed = 1;
        }
        let busy: int = 0;
        if ((st & 2) != 0) {
            let buf: int = br_ssl_engine_sendrec_buf(TLS_SC, TLS_LENP);
            let len: int = volatile_load32(TLS_LENP);
            if (len > 0) {
                uip_glue_send(buf, len);
                br_ssl_engine_sendrec_ack(TLS_SC, len);
                busy = 1;
            }
        }
        if ((st & 4) != 0) {
            let buf: int = br_ssl_engine_recvrec_buf(TLS_SC, TLS_LENP);
            let cap: int = volatile_load32(TLS_LENP);
            let n: int = tls_glue_recv_tls(buf, cap);
            if (n > 0) {
                br_ssl_engine_recvrec_ack(TLS_SC, n);
                busy = 1;
            }
        }
        if (closed == 1) {
            /* 关闭后：等引擎处理完当前数据（close_notify 在最后） */
            if (busy == 0) {
                serial_print("tls closed err=");
                print_int(pp_tls_last_error(TLS_SC));
                serial_putc(10);
                return 1;
            }
            hlt();
            continue;
        }
        if (uip_glue_closed() == 1) {
            /* uIP 连接关闭（FIN/超时）——数据已全部到达 */
            if (busy == 0) {
                serial_print("tls conn closed\n");
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

/* TCP 连接（uIP 发起三次握手），等待 connected/closed */
fn tcp_connect(dst_ip: int, dst_port: int) -> int {
    if (uip_glue_connect(dst_ip, dst_port) != 0) {
        serial_print("uip connect fail\n");
        return 1;
    }
    let t: int = 0;
    while (t < 3000) {
        uip_glue_poll();
        if (uip_glue_connected() == 1) {
            serial_print("tcp connected\n");
            return 0;
        }
        if (uip_glue_closed() == 1 || uip_glue_timedout() == 1) {
            serial_print("no synack\n");
            return 1;
        }
        hlt();
        t = t + 1;
    }
    serial_print("no synack\n");
    return 1;
}

/* TLS 数据接收：从 glue 缓冲取字节喂 BearSSL recvrec */
fn tls_glue_recv_tls(buf: int, cap: int) -> int {
    return uip_glue_recv(buf, cap);
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
    let tmp: [12]u8;
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
