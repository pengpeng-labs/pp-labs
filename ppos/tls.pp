/* TLS 集成：用 BearSSL 做 HTTPS 客户端（pump loop + 应用数据收发） */

/* BearSSL extern 声明 */
extern fn br_ssl_client_init_full(sc: u64, xc: u64, ta: u64, ta_num: int);
extern fn br_ssl_engine_set_buffer(eng: u64, buf: u64, len: int, bidi: int);
extern fn br_ssl_engine_inject_entropy(eng: u64, data: u64, len: int);
extern fn br_ssl_client_reset(sc: u64, name: u64, resume: int) -> int;
extern fn br_ssl_engine_current_state(eng: u64) -> int;
extern fn br_ssl_engine_sendrec_buf(eng: u64, lenp: u64) -> u64;
extern fn br_ssl_engine_sendrec_ack(eng: u64, len: int);
extern fn br_ssl_engine_recvrec_buf(eng: u64, lenp: u64) -> u64;
extern fn br_ssl_engine_recvrec_ack(eng: u64, len: int);
extern fn br_ssl_engine_sendapp_buf(eng: u64, lenp: u64) -> u64;
extern fn br_ssl_engine_sendapp_ack(eng: u64, len: int);
extern fn br_ssl_engine_recvapp_buf(eng: u64, lenp: u64) -> u64;
extern fn br_ssl_engine_recvapp_ack(eng: u64, len: int);
extern fn br_ssl_engine_flush(eng: u64, force: int);
extern fn br_ssl_engine_last_error(eng: u64) -> int;
extern fn pp_tls_set_knownkey(sc: u64);
extern fn pp_tls_last_error(sc: u64) -> int;
extern fn pp_tls_contract_check(sc_cap: int, xc_cap: int, io_cap: int) -> int;
extern fn pp_tls_session_begin() -> int;
extern fn pp_tls_session_end();
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
extern fn uip_glue_last_error() -> int;
extern fn uip_glue_contract_selftest() -> int;

/* 固定内存布局 */
static TLS_SC: int = 0x660000;      /* br_ssl_client_context (3720B) */
static TLS_XC: int = 0x661000;      /* br_x509_minimal_context (3168B) */
static TLS_RNG: int = 0x662000;     /* br_hmac_drbg_context (144B) */
static TLS_SEED: int = 0x662100;    /* 熵种子 (32B) */
static TLS_BUF: int = 0x663000;     /* BR_SSL_BUFSIZE_BIDI (33178B) */
static TLS_LENP: int = 0x66F000;    /* len 指针暂存 */
static TLS_RESP: int = 0x670000;    /* HTTPS 响应缓冲 */

/* 引擎 = sc + 0（第一个成员） */

fn glue_contract_selftest() -> bool {
    if (uip_glue_contract_selftest() != 1
        || pp_tls_contract_check(4096, 4096, 49152) != 1) {
        return false;
    }
    if (pp_tls_session_begin() != 0) {
        return false;
    }
    if (pp_tls_session_begin() != -2) {
        pp_tls_session_end();
        return false;
    }
    pp_tls_session_end();
    if (pp_tls_session_begin() != 0) {
        return false;
    }
    pp_tls_session_end();
    return true;
}

fn tls_init(host: str) -> bool {
    if (pp_tls_contract_check(4096, 4096, 49152) != 1
        || pp_tls_session_begin() != 0) {
        return false;
    }
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
    if (br_ssl_client_reset(TLS_SC, ptr_to_int(host), 0) == 0) {
        pp_tls_session_end();
        return false;
    }
    return true;
}

/* 泵循环：处理引擎发送/接收，直到 done_mask 满足且无待发数据。
   每次迭代：uip_glue_poll（收帧/重传驱动）+ 引擎数据交换
   guard 8000 = 约 80 秒超时（每轮含 10ms 让出） */
fn tls_pump(dst_ip: u64, dst_port: int, done_mask: int) -> int {
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
            let buf: u64 = br_ssl_engine_sendrec_buf(TLS_SC, TLS_LENP);
            let len: int = volatile_load32(TLS_LENP);
            if (len > 0) {
                let sent: int = uip_glue_send(buf, len);
                if (sent == len) {
                    br_ssl_engine_sendrec_ack(TLS_SC, len);
                    busy = 1;
                } else if (sent != -2) {
                    console_write("tls transport send rejected\n");
                    return 1;
                }
            }
        }
        if ((st & 4) != 0) {
            let buf: u64 = br_ssl_engine_recvrec_buf(TLS_SC, TLS_LENP);
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
                console_write("tls closed err=");
                print_int(pp_tls_last_error(TLS_SC));
                console_putc(10);
                return 1;
            }
            hlt();
            continue;
        }
        if (uip_glue_closed() == 1) {
            /* uIP 连接关闭（FIN/超时）——数据已全部到达 */
            if (busy == 0) {
                console_write("tls conn closed\n");
                return 1;
            }
            hlt();
            continue;
        }
        if (uip_glue_last_error() < 0) {
            console_write("tls transport boundary error\n");
            return 1;
        }
        if ((st & done_mask) != 0) {
            if ((st & 2) == 0) {
                return 0;
            }
        }
        hlt();
    }
    console_write("tls pump timeout\n");
    return 1;
}

/* 发送应用数据（HTTP 请求）并经 TLS 加密送出 */
fn tls_send(dst_ip: u64, dst_port: int, data: u64, len: int) -> bool {
    if (len < 0 || (len > 0 && data == (0 as u64))) {
        return false;
    }
    let offset: int = 0;
    while (offset < len) {
        let buf: u64 = br_ssl_engine_sendapp_buf(TLS_SC, TLS_LENP);
        let cap: int = volatile_load32(TLS_LENP);
        if (cap <= 0) {
            return false;
        }
        let n: int = len - offset;
        if (n > cap) {
            n = cap;
        }
        let i: int = 0;
        while (i < n) {
            volatile_store8(buf + i, volatile_load8(data + offset + i));
            i = i + 1;
        }
        br_ssl_engine_sendapp_ack(TLS_SC, n);
        br_ssl_engine_flush(TLS_SC, 1);
        if (tls_pump(dst_ip, dst_port, 8) != 0) {
            return false;
        }
        offset = offset + n;
    }
    return true;
}

/* 接收应用数据（HTTPS 响应），返回长度。
   即使连接已关闭（服务器 Connection: close），也要读空 recvapp 残留数据 */
fn tls_recv(dst_ip: u64, dst_port: int, buf: u64, cap: int) -> int {
    let r: int = tls_pump(dst_ip, dst_port, 16);
    let abuf: u64 = br_ssl_engine_recvapp_buf(TLS_SC, TLS_LENP);
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
fn tcp_connect(dst_ip: u64, dst_port: int) -> int {
    if (uip_glue_connect(dst_ip, dst_port) != 0) {
        console_write("uip connect fail\n");
        return 1;
    }
    let t: int = 0;
    while (t < 3000) {
        uip_glue_poll();
        if (uip_glue_connected() == 1) {
            console_write("tcp connected\n");
            return 0;
        }
        if (uip_glue_closed() == 1 || uip_glue_timedout() == 1) {
            console_write("no synack\n");
            return 1;
        }
        hlt();
        t = t + 1;
    }
    console_write("no synack\n");
    return 1;
}

/* TLS 数据接收：从 glue 缓冲取字节喂 BearSSL recvrec */
fn tls_glue_recv_tls(buf: u64, cap: int) -> int {
    return uip_glue_recv(buf, cap);
}

/* HTTPS GET：TCP 连接 + TLS 握手 + GET 请求 + 收响应 */
fn https_get(dst_ip: u64, dst_port: int, host: str, path: str) {
    if (tcp_connect(dst_ip, dst_port) != 0) {
        return;
    }
    if (!tls_init(host)) {
        console_write("tls boundary busy or invalid\n");
        return;
    }
    let r: int = tls_pump(dst_ip, dst_port, 8);
    if (r != 0) {
        console_write("tls handshake fail\n");
        pp_tls_session_end();
        return;
    }
    /* 构建 GET 请求 */
    let request: BoundedWriter = writer_new(0x66E000 as u64, 4096);
    writer_write_str(&request, "GET ");
    writer_write_cstr(&request, ptr_to_int(path), 1024);
    writer_write_str(&request, " HTTP/1.1\r\nHost: ");
    writer_write_cstr(&request, ptr_to_int(host), 512);
    writer_write_str(&request, "\r\nConnection: close\r\n\r\n");
    if (request.failed) {
        console_write("https request too large\n");
        pp_tls_session_end();
        return;
    }
    if (!tls_send(dst_ip, dst_port, request.data, request.len)) {
        console_write("https send failed\n");
        pp_tls_session_end();
        return;
    }
    console_write("https sent\n");
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
        console_write("HTTPS response (");
        print_int(resp_len);
        console_write(" bytes):\n");
        let j: int = 0;
        while (j < resp_len && j < 600) {
            console_putc(volatile_load8(TLS_RESP + j));
            j = j + 1;
        }
        console_putc(10);
    } else {
        console_write("no https response\n");
    }
    pp_tls_session_end();
}

/* DeepSeek API key：从 0x400600 读取（由 ds 命令从文件系统 "key" 文件载入） */
fn api_key_str() -> str {
    return int_to_ptr(0x400600);
}

/* HTTPS POST：返回 service-owned 明文响应 view。 */
fn https_post(dst_ip: u64, dst_port: int, host: str, path: str, body: u64, body_len: int) -> ServiceBytes {
    let response: ServiceBytes = service_bytes_empty();
    if (tcp_connect(dst_ip, dst_port) != 0) {
        return response;
    }
    if (!tls_init(host)) {
        console_write("tls boundary busy or invalid\n");
        return response;
    }
    let r: int = tls_pump(dst_ip, dst_port, 8);
    if (r != 0) {
        console_write("tls handshake fail\n");
        pp_tls_session_end();
        return response;
    }
    /* 构建 POST 请求 */
    let request: BoundedWriter = writer_new(0x66E000 as u64, 4096);
    writer_write_str(&request, "POST ");
    writer_write_cstr(&request, ptr_to_int(path), 1024);
    writer_write_str(&request, " HTTP/1.1\r\nHost: ");
    writer_write_cstr(&request, ptr_to_int(host), 512);
    writer_write_str(&request, "\r\nAuthorization: Bearer ");
    writer_write_cstr(&request, ptr_to_int(api_key_str()), 256);
    writer_write_str(&request, "\r\nContent-Type: application/json\r\nContent-Length: ");
    writer_write_uint(&request, body_len);
    writer_write_str(&request, "\r\nConnection: close\r\n\r\n");
    writer_write_bytes(&request, body, body_len);
    if (request.failed) {
        console_write("https request too large\n");
        pp_tls_session_end();
        return response;
    }
    if (!tls_send(dst_ip, dst_port, request.data, request.len)) {
        console_write("https send failed\n");
        pp_tls_session_end();
        return response;
    }
    console_write("https post sent\n");
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
        console_write("HTTPS response (");
        print_int(resp_len);
        console_write(" bytes)\n");
        let j: int = 0;
        while (j < resp_len && j < 700) {
            console_putc(volatile_load8(TLS_RESP + j));
            j = j + 1;
        }
        console_putc(10);
    } else {
        console_write("no https response\n");
    }
    if (resp_len > 0) {
        response.data = TLS_RESP as u64;
        response.len = resp_len;
        response.ok = true;
    }
    pp_tls_session_end();
    return response;
}
