/* e1000 (Intel 82540EM) 网卡驱动：PCI 枚举 + MMIO + 收发描述符环 */

static e1000_base: int = 0;   /* 启动时由 PCI 枚举填充 */

static tx_ring: int = 0;   /* 发送描述符环地址 */
static rx_ring: int = 0;   /* 接收描述符环地址 */
static tx_buf: int = 0;    /* 发送缓冲区 */
static rx_buf: int = 0;    /* 接收缓冲区 */
static tx_tail: int = 0;   /* 发送尾指针 */
static rx_tail: int = 0;   /* 接收尾指针 */

static net_ok: int = 0;
static my_mac: [u8; 6];
static my_ip: [u8; 4];
static gateway_mac: [u8; 6];
static dns_resolved: [u8; 4];
static http_len: int = 0;

fn mmio_read(off: int) -> int {
    return volatile_load32(e1000_base + off);
}

fn mmio_write(off: int, val: int) {
    volatile_store32(e1000_base + off, val);
}

/* PCI 配置空间读 32 位 */
fn pci_read32(bus: int, dev: int, func: int, reg: int) -> int {
    let addr: int = 0x80000000 | (bus << 16) | (dev << 11) | (func << 8) | (reg & 0xFC);
    outl(0xCF8, addr);
    return inl(0xCFC);
}

/* PCI 配置空间写 32 位 */
fn pci_write32(bus: int, dev: int, func: int, reg: int, val: int) {
    let addr: int = 0x80000000 | (bus << 16) | (dev << 11) | (func << 8) | (reg & 0xFC);
    outl(0xCF8, addr);
    outl(0xCFC, val);
}

/* 找 e1000（vendor 0x8086, device 0x100E）所在的 PCI 设备号 */
fn pci_find_e1000() -> int {
    let dev: int = 0;
    while (dev < 32) {
        let id: int = pci_read32(0, dev, 0, 0);
        if ((id & 0xFFFF) == 0x8086) {
            if (((id >> 16) & 0xFFFF) == 0x100E) {
                return dev;
            }
        }
        dev = dev + 1;
    }
    return -1;
}

/* 读 EEPROM 一个字 */
fn eeprom_read(addr: int) -> int {
    mmio_write(0x14, (addr * 256) | 1);   /* EERD：start 位 + 地址 */
    while ((mmio_read(0x14) & 16) == 0) {  /* 等 DONE 位 */
    }
    return (mmio_read(0x14) >> 16) & 0xFFFF;
}

/* 读 MAC 地址（6 字节，写回 mac 缓冲） */
fn e1000_mac(mac: int) {
    let w0: int = eeprom_read(0);
    let w1: int = eeprom_read(1);
    let w2: int = eeprom_read(2);
    volatile_store8(mac + 0, w0 & 0xFF);
    volatile_store8(mac + 1, (w0 >> 8) & 0xFF);
    volatile_store8(mac + 2, w1 & 0xFF);
    volatile_store8(mac + 3, (w1 >> 8) & 0xFF);
    volatile_store8(mac + 4, w2 & 0xFF);
    volatile_store8(mac + 5, (w2 >> 8) & 0xFF);
}

/* 写发送描述符（标准 e1000 布局：buffer_addr 0-7，length 8-9，cmd 11，status 12） */
fn tx_desc(idx: int, addr: int, len: int) {
    let p: int = tx_ring + idx * 16;
    volatile_store32(p, addr);          /* buffer addr low */
    volatile_store32(p + 4, 0);         /* buffer addr high */
    volatile_store16(p + 8, len);       /* length */
    volatile_store8(p + 10, 0);         /* CSO */
    volatile_store8(p + 11, 0x0B);      /* CMD: EOP | IFCS | RS */
    volatile_store8(p + 12, 0);         /* status */
    volatile_store8(p + 13, 0);         /* CSS */
    volatile_store16(p + 14, 0);        /* special */
}

/* 写接收描述符 */
fn rx_desc(idx: int, addr: int) {
    let p: int = rx_ring + idx * 16;
    volatile_store32(p, addr);
    volatile_store32(p + 4, 0);
    volatile_store16(p + 8, 0);
    volatile_store16(p + 10, 0);
    volatile_store8(p + 12, 0);
    volatile_store8(p + 13, 0);
    volatile_store16(p + 14, 0);
}

fn e1000_init() {
    /* PCI 枚举找 BAR0 */
    let dev: int = pci_find_e1000();
    if (dev < 0) {
        net_ok = 0;
        return;
    }
    let bar0: int = pci_read32(0, dev, 0, 0x10);
    e1000_base = bar0 & 0xFFFFFFF0;

    /* 开启 PCI Bus Master（DMA 必需，否则描述符读写无效） */
    let cmd: int = pci_read32(0, dev, 0, 4);
    pci_write32(0, dev, 0, 4, cmd | 0x04);

    /* 关闭所有中断 */
    mmio_write(0xD8, 0xFFFFFFFF);  /* IMC */

    /* 复位设备 */
    mmio_write(0x00, mmio_read(0x00) | 0x04000000);  /* CTRL.RST */
    while ((mmio_read(0x00) & 0x04000000) != 0) {
    }

    /* 关闭中断 + 强制链路 up（SLU | ASDE） */
    mmio_write(0xD8, 0xFFFFFFFF);
    mmio_write(0x00, mmio_read(0x00) | 0x60);  /* SLU | ASDE */

    /* 读 MAC 并设置接收地址（RAL/RAH，单播必需） */
    e1000_mac(ptr_to_int(&my_mac[0]));
    mmio_write(0x5400, my_mac[0] | (my_mac[1] << 8) | (my_mac[2] << 16) | (my_mac[3] << 24));
    mmio_write(0x5404, my_mac[4] | (my_mac[5] << 8) | 0x80000000);

    /* 分配环与缓冲区 */
    tx_ring = kmalloc(32 * 16);
    rx_ring = kmalloc(32 * 16);
    tx_buf = kmalloc(32 * 2048);
    rx_buf = kmalloc(32 * 2048);

    /* 初始化发送描述符 */
    let i: int = 0;
    while (i < 32) {
        tx_desc(i, tx_buf + i * 2048, 0);
        rx_desc(i, rx_buf + i * 2048);
        i = i + 1;
    }
    tx_tail = 0;
    rx_tail = 31;   /* 与 RDT 寄存器一致：下一个待收描述符 = (31+1)%32 = 0 */

    /* 配置发送环 */
    mmio_write(0x3800, tx_ring);      /* TDBAL */
    mmio_write(0x3804, 0);            /* TDBAH */
    mmio_write(0x3808, 32 * 16);      /* TDLEN */
    mmio_write(0x3810, 0);            /* TDH */
    mmio_write(0x3818, 0);            /* TDT */

    /* 配置接收环 */
    mmio_write(0x2800, rx_ring);      /* RDBAL */
    mmio_write(0x2804, 0);            /* RDBAH */
    mmio_write(0x2808, 32 * 16);      /* RDLEN */
    mmio_write(0x2810, 0);            /* RDH */
    mmio_write(0x2818, 31);           /* RDT */

    /* 使能发送（EN | PSP，同 eggos） */
    mmio_write(0x0400, 0x0000000A);   /* TCTL */
    mmio_write(0x0410, 0x0060200A);   /* TIPG */

    /* 使能接收（EN | BAM | SECRC | 256 字节） */
    mmio_write(0x0100, 0x04008002);   /* RCTL */

    net_ok = 1;
}

/* 发送一帧：data=数据地址，len=长度 */
fn e1000_send(data: int, len: int) {
    let idx: int = tx_tail;
    let i: int = 0;
    let b: int = tx_buf + idx * 2048;
    while (i < len) {
        volatile_store8(b + i, volatile_load8(data + i));
        i = i + 1;
    }
    tx_desc(idx, b, len);
    let nt: int = (idx + 1) % 32;
    tx_tail = nt;
    mmio_write(0x3818, nt);  /* TDT */
    /* 等 DD 位（status 在偏移 12），有界 */
    let dp: int = tx_ring + idx * 16;
    let tries: int = 0;
    while ((volatile_load8(dp + 12) & 1) == 0) {
        tries = tries + 1;
        if (tries > 100000) {
            serial_print("tx timeout, sta=");
            print_byte_hex(volatile_load8(dp + 12));
            serial_print(" tdh=");
            print_int(mmio_read(0x3810));
            serial_putc(10);
            return;
        }
    }
    serial_print("tx done\n");
}

/* 查询接收：返回收到帧的长度，0 表示无帧；数据写到 dst */
fn e1000_recv(dst: int) -> int {
    let rdt: int = rx_tail;
    let ni: int = (rdt + 1) % 32;
    let p: int = rx_ring + ni * 16;
    let st: int = volatile_load8(p + 12);
    if ((st & 1) == 0) {
        let rdh: int = mmio_read(0x2810);
        if (rdh != 0) {
            serial_print("rx: rdh=");
            print_int(rdh);
            serial_print(" ni=");
            print_int(ni);
            serial_print(" st=");
            print_byte_hex(st);
            serial_putc(10);
        }
        return 0;   /* 无新帧（DD 未置位） */
    }
    let len: int = volatile_load16(p + 8);
    let src: int = rx_buf + ni * 2048;
    let i: int = 0;
    while (i < len) {
        volatile_store8(dst + i, volatile_load8(src + i));
        i = i + 1;
    }
    rx_tail = ni;
    mmio_write(0x2818, ni);  /* RDT：归还描述符 */
    return len;
}

fn hex_char(d: int) -> int {
    if (d < 10) {
        return 48 + d;
    }
    return 55 + d;
}fn print_byte_hex(b: int) {
    serial_putc(hex_char((b >> 4) & 15));
    serial_putc(hex_char(b & 15));
}

fn print_hex(n: int) {
    let i: int = 28;
    while (i >= 0) {
        serial_putc(hex_char((n >> i) & 15));
        i = i - 4;
    }
}

fn print_int(n: int) {
    if (n == 0) {
        serial_putc(48);
        return;
    }
    if (n < 0) {
        serial_putc(45);
        n = 0 - n;
    }
    let buf: [u8; 12];
    let i: int = 0;
    while (n > 0) {
        buf[i] = 48 + (n % 10);
        n = n / 10;
        i = i + 1;
    }
    while (i > 0) {
        i = i - 1;
        serial_putc(buf[i]);
    }
}

/* 用 val 填充 n 字节 */
fn fill(dst: int, val: int, n: int) {
    let i: int = 0;
    while (i < n) {
        volatile_store8(dst + i, val);
        i = i + 1;
    }
}

/* 发送 ARP 请求（target 指向 4 字节 IP） */
fn arp_request(target: int) {
    let p: int = 0x600000;
    fill(p, 0xFF, 6);                    /* 以太网广播 */
    let i: int = 0;
    while (i < 6) {
        volatile_store8(p + 6 + i, my_mac[i]);   /* 源 MAC */
        i = i + 1;
    }
    volatile_store8(p + 12, 0x08);       /* ethertype = ARP */
    volatile_store8(p + 13, 0x06);
    volatile_store8(p + 14, 0x00);       /* htype = 1 */
    volatile_store8(p + 15, 0x01);
    volatile_store8(p + 16, 0x08);       /* ptype = 0x0800 */
    volatile_store8(p + 17, 0x00);
    volatile_store8(p + 18, 6);          /* hlen */
    volatile_store8(p + 19, 4);          /* plen */
    volatile_store8(p + 20, 0x00);       /* op = 1 (request) */
    volatile_store8(p + 21, 0x01);
    i = 0;
    while (i < 6) {
        volatile_store8(p + 22 + i, my_mac[i]);  /* sha */
        i = i + 1;
    }
    i = 0;
    while (i < 4) {
        volatile_store8(p + 28 + i, my_ip[i]);   /* spa */
        i = i + 1;
    }
    fill(p + 32, 0, 6);                  /* tha = 0 */
    i = 0;
    while (i < 4) {
        volatile_store8(p + 38 + i, volatile_load8(target + i));  /* tpa */
        i = i + 1;
    }
    e1000_send(p, 42);
}

/* 大端 16 位写（网络字节序） */
fn store_be16(addr: int, val: int) {
    volatile_store8(addr, (val >> 8) & 0xFF);
    volatile_store8(addr + 1, val & 0xFF);
}

/* 字符串长度 */
fn str_len(s: str) -> int {
    let i: int = 0;
    while (s[i] != 0) {
        i = i + 1;
    }
    return i;
}

/* 大端 32 位写/读 */
fn store_be32(addr: int, val: int) {
    volatile_store8(addr, (val >> 24) & 0xFF);
    volatile_store8(addr + 1, (val >> 16) & 0xFF);
    volatile_store8(addr + 2, (val >> 8) & 0xFF);
    volatile_store8(addr + 3, val & 0xFF);
}

fn load_be32(addr: int) -> int {
    return (volatile_load8(addr) << 24) | (volatile_load8(addr + 1) << 16)
        | (volatile_load8(addr + 2) << 8) | volatile_load8(addr + 3);
}

fn load_be16(addr: int) -> int {
    return (volatile_load8(addr) << 8) | volatile_load8(addr + 1);
}

/* IPv4 头校验和（RFC 1071） */
fn ip_checksum(data: int, len: int) -> int {
    let sum: int = 0;
    let i: int = 0;
    while (i < len) {
        sum = sum + (volatile_load8(data + i) << 8);
        if (i + 1 < len) {
            sum = sum + volatile_load8(data + i + 1);
        }
        i = i + 2;
    }
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (0xFFFF - sum) & 0xFFFF;
}

/* 16 位大端和累加（RFC 1071，可分段累加） */
fn csum_add(sum: int, data: int, len: int) -> int {
    let i: int = 0;
    while (i < len) {
        sum = sum + (volatile_load8(data + i) << 8);
        if (i + 1 < len) {
            sum = sum + volatile_load8(data + i + 1);
        }
        i = i + 2;
    }
    return sum;
}

/* UDP 校验和：伪头部 + UDP 头（checksum=0）+ payload */
fn udp_checksum(src_ip: int, dst_ip: int, udp: int, udp_len: int) -> int {
    let ph: int = 0x640000;
    let i: int = 0;
    while (i < 4) {
        volatile_store8(ph + i, volatile_load8(src_ip + i));
        volatile_store8(ph + 4 + i, volatile_load8(dst_ip + i));
        i = i + 1;
    }
    volatile_store8(ph + 8, 0);
    volatile_store8(ph + 9, 17);
    volatile_store8(ph + 10, (udp_len >> 8) & 0xFF);
    volatile_store8(ph + 11, udp_len & 0xFF);
    let sum: int = csum_add(0, ph, 12);
    let sum2: int = csum_add(sum, udp, udp_len);
    let s: int = sum2;
    while (s > 0xFFFF) {
        s = (s & 0xFFFF) + (s >> 16);
    }
    if (s == 0xFFFF) {
        s = 0;
    }
    return (0xFFFF - s) & 0xFFFF;
}

/* 发送 UDP 包（dst_ip 指向 4 字节 IP，dst_port 端口）——DNS 用 */
fn udp_send(dst_ip: int, dst_port: int, payload: int, payload_len: int) {
    let p: int = 0x620000;
    let i: int = 0;
    while (i < 6) {
        volatile_store8(p + i, gateway_mac[i]);
        i = i + 1;
    }
    i = 0;
    while (i < 6) {
        volatile_store8(p + 6 + i, my_mac[i]);
        i = i + 1;
    }
    volatile_store8(p + 12, 0x08);
    volatile_store8(p + 13, 0x00);
    volatile_store8(p + 14, 0x45);
    volatile_store8(p + 15, 0x00);
    store_be16(p + 16, 20 + 8 + payload_len);
    store_be16(p + 18, 0x1234);
    store_be16(p + 20, 0x0000);
    volatile_store8(p + 22, 64);
    volatile_store8(p + 23, 17);
    store_be16(p + 24, 0);
    volatile_store8(p + 26, 10);
    volatile_store8(p + 27, 0);
    volatile_store8(p + 28, 2);
    volatile_store8(p + 29, 15);
    i = 0;
    while (i < 4) {
        volatile_store8(p + 30 + i, volatile_load8(dst_ip + i));
        i = i + 1;
    }
    store_be16(p + 24, ip_checksum(p + 14, 20));
    store_be16(p + 34, 12345);
    store_be16(p + 36, dst_port);
    let udp_len: int = 8 + payload_len;
    store_be16(p + 38, udp_len);
    store_be16(p + 40, 0);
    i = 0;
    while (i < payload_len) {
        volatile_store8(p + 42 + i, volatile_load8(payload + i));
        i = i + 1;
    }
    store_be16(p + 40, udp_checksum(p + 26, p + 30, p + 34, udp_len));
    e1000_send(p, 42 + payload_len);
}

fn dns_query(host: str) {
    let q: int = 0x630000;
    store_be16(q, 0x1234);
    store_be16(q + 2, 0x0100);
    store_be16(q + 4, 1);
    store_be16(q + 6, 0);
    store_be16(q + 8, 0);
    store_be16(q + 10, 0);
    /* QNAME：label 编码 */
    let i: int = 0;
    let j: int = 12;
    while (host[i] != 0) {
        let start: int = i;
        while (host[i] != 46 && host[i] != 0) {
            i = i + 1;
        }
        volatile_store8(q + j, i - start);
        j = j + 1;
        let k: int = start;
        while (k < i) {
            volatile_store8(q + j, host[k]);
            j = j + 1;
            k = k + 1;
        }
        if (host[i] == 46) {
            i = i + 1;
        }
    }
    volatile_store8(q + j, 0);
    j = j + 1;
    store_be16(q + j, 1);
    store_be16(q + j + 2, 1);
    let qlen: int = j + 4;
    uip_glue_dns_send(q, qlen);
    serial_print("dns sent\n");
}

/* DNS 响应（uIP UDP 回调 → pp 解析） */
fn pp_dns_recv(buf: u64, len: int) {
    dns_parse(buf, len);
}

/* 解析 DNS 响应：遍历 answers 找 A 记录（TYPE=1），打印 IP */
fn dns_parse(d: int, len: int) {
    let i: int = 12;
    /* 跳过 question（QNAME + QTYPE + QCLASS） */
    while (i < len) {
        let b: int = volatile_load8(d + i);
        if (b == 0) {
            i = i + 1;
            break;
        }
        if ((b & 0xC0) == 0xC0) {
            i = i + 2;
            break;
        }
        i = i + b + 1;
    }
    i = i + 4;
    /* 遍历 answers */
    while (i + 12 < len) {
        /* NAME：指针（0xC0）或标签 */
        let nb: int = volatile_load8(d + i);
        if ((nb & 0xC0) == 0xC0) {
            i = i + 2;
        } else {
            while (volatile_load8(d + i) != 0) {
                i = i + volatile_load8(d + i) + 1;
            }
            i = i + 1;
        }
        /* TYPE(2) + CLASS(2) + TTL(4) + RDLENGTH(2) + RDATA */
        let atype: int = (volatile_load8(d + i) << 8) | volatile_load8(d + i + 1);
        let rdlen: int = (volatile_load8(d + i + 8) << 8) | volatile_load8(d + i + 9);
        if (atype == 1 && rdlen == 4) {
            let ip: int = d + i + 10;
            dns_resolved[0] = volatile_load8(ip) & 0xFF;
            dns_resolved[1] = volatile_load8(ip + 1) & 0xFF;
            dns_resolved[2] = volatile_load8(ip + 2) & 0xFF;
            dns_resolved[3] = volatile_load8(ip + 3) & 0xFF;
            serial_print("DNS ip: ");
            print_int(dns_resolved[0]);
            serial_putc(46);
            print_int(dns_resolved[1]);
            serial_putc(46);
            print_int(dns_resolved[2]);
            serial_putc(46);
            print_int(dns_resolved[3]);
            serial_putc(10);
        }
        i = i + 10 + rdlen;
    }
    serial_print("DNS: no A record\n");
}

fn http_get(dst_ip: int, dst_port: int, path: str) {
    /* 简化：HTTP/1.0 请求 → 复用 http_get_host（Host 头为空串） */
    let rl: int = http_get_host(dst_ip, dst_port, int_to_ptr(0), path);
    if (rl > 0) {
        serial_print("HTTP response (");
        print_int(rl);
        serial_print(" bytes)\n");
        let j: int = 0;
        while (j < rl && j < 600) {
            serial_putc(volatile_load8(0x650000 + j));
            j = j + 1;
        }
        serial_putc(10);
    } else {
        serial_print("no response\n");
    }
}

/* HTTP GET（任意主机，HTTP/1.1 + Host 头）：响应存 0x650000，返回长度 */
fn http_get_host(dst_ip: int, dst_port: int, host: str, path: str) -> int {
    /* uIP 连接 + 发送 */
    if (uip_glue_connect(dst_ip, dst_port) != 0) {
        serial_print("uip connect fail\n");
        return 0;
    }
    let t: int = 0;
    while (t < 3000) {
        uip_glue_poll();
        if (uip_glue_connected() == 1) {
            break;
        }
        if (uip_glue_closed() == 1) {
            serial_print("no synack\n");
            return 0;
        }
        hlt();
        t = t + 1;
    }
    if (uip_glue_connected() != 1) {
        serial_print("no synack\n");
        return 0;
    }
    /* 构建 GET <path> HTTP/1.1\r\nHost: <host>\r\nConnection: close\r\n\r\n */
    let req: int = 0x630100;
    let ri: int = 0;
    let h1: str = "GET ";
    let i: int = 0;
    while (h1[i] != 0) {
        volatile_store8(req + ri, h1[i]);
        ri = ri + 1;
        i = i + 1;
    }
    let plen: int = str_len(path);
    i = 0;
    while (i < plen) {
        volatile_store8(req + ri, path[i]);
        ri = ri + 1;
        i = i + 1;
    }
    let h2: str = " HTTP/1.1\r\nHost: ";
    i = 0;
    while (h2[i] != 0) {
        volatile_store8(req + ri, h2[i]);
        ri = ri + 1;
        i = i + 1;
    }
    let hl: int = str_len(host);
    i = 0;
    while (i < hl) {
        volatile_store8(req + ri, host[i]);
        ri = ri + 1;
        i = i + 1;
    }
    let h3: str = "\r\nConnection: close\r\n\r\n";
    i = 0;
    while (h3[i] != 0) {
        volatile_store8(req + ri, h3[i]);
        ri = ri + 1;
        i = i + 1;
    }
    uip_glue_send(req, ri);
    serial_print("http sent\n");
    /* 收响应：从 glue 缓冲读 */
    http_len = 0;
    let t2: int = 0;
    let idle: int = 0;
    while (t2 < 3000 && idle < 20) {
        let before: int = http_len;
        uip_glue_poll();
        let n: int = uip_glue_recv(0x650000 + http_len, 2048);
        http_len = http_len + n;
        hlt();
        t2 = t2 + 1;
        if (http_len == before) {
            idle = idle + 1;
        } else {
            idle = 0;
        }
        if (uip_glue_closed() == 1 && n == 0) {
            break;
        }
    }
    return http_len;
}

/* ---- uIP glue 桥接（C 侧调用） ---- */

/* e1000 收帧（glue 用）：dst 为 C 侧帧缓冲（u64 地址），返回帧长 */
fn pp_e1000_recv(dst: u64) -> int {
    return e1000_recv(dst);
}

/* e1000 发帧（glue 用） */
fn pp_e1000_send(buf: u64, len: int) {
    e1000_send(buf, len);
}
/* UDP 帧暂存（glue 拦截 DNS 响应 → pp 解析） */
static udp_frame: [u8; 600];
static udp_frame_len: int = 0;

/* 网关 MAC 回填（glue ARP reply 调用） */
fn pp_set_gateway_mac(mac: u64) {
    let i: int = 0;
    while (i < 6) {
        gateway_mac[i] = volatile_load8(mac + i);
        i = i + 1;
    }
}

/* glue 调试打印 */
fn pp_dbg(s: str) {
    serial_print(s);
}

fn pp_dbg_int(v: int) {
    serial_putc(91);
    if (v == 1) {
        serial_print("ARP");
    } else if (v == 2) {
        serial_print("IP");
    } else {
        serial_print("??");
    }
    serial_putc(93);
    serial_putc(10);
}

/* glue 调试：打印 TCP SYN 帧关键字段 */
fn pp_dbg_frame(p: u64, len: int) {
    serial_print("TX len=");
    print_int(len);
    serial_print(" eth=");
    print_byte_hex(volatile_load8(p + 12));
    print_byte_hex(volatile_load8(p + 13));
    if (len > 34) {
        serial_print(" ipdst=");
        print_int(volatile_load8(p + 30));
        serial_putc(46);
        print_int(volatile_load8(p + 31));
        serial_putc(46);
        print_int(volatile_load8(p + 32));
        serial_putc(46);
        print_int(volatile_load8(p + 33));
        serial_print(" sport=");
        print_int((volatile_load8(p + 34) << 8) | volatile_load8(p + 35));
        serial_print(" dport=");
        print_int((volatile_load8(p + 36) << 8) | volatile_load8(p + 37));
        serial_print(" flags=");
        print_byte_hex(volatile_load8(p + 47));
        serial_print(" tcpcs=");
        print_byte_hex(volatile_load8(p + 50));
        print_byte_hex(volatile_load8(p + 51));
    }
    serial_putc(10);
}

fn pp_udp_frame(buf: u64, len: int) {
    /* 回填网关 MAC（源 MAC 即网关）——手写 DNS UDP 发送需要 */
    let i: int = 0;
    while (i < 6) {
        gateway_mac[i] = volatile_load8(buf + 6 + i);
        i = i + 1;
    }
    i = 0;
    while (i < len && i < 600) {
        udp_frame[i] = volatile_load8(buf + i);
        i = i + 1;
    }
    udp_frame_len = i;
    dns_parse(ptr_to_int(&udp_frame[42]), udp_frame_len - 42);
}

/* PIT tick（glue 时钟用，100Hz） */
fn pp_ticks() -> int {
    return tick_count_global();
}

/* 轮询网络（uIP 驱动 + DNS）：返回 1 有事件 */
fn net_poll() -> int {
    return uip_glue_poll();
}

fn net_init() {
    e1000_init();
    if (net_ok == 1) {
        e1000_mac(ptr_to_int(&my_mac[0]));
        my_ip[0] = 10;
        my_ip[1] = 0;
        my_ip[2] = 2;
        my_ip[3] = 15;   /* QEMU 用户网络默认客户机 IP */
        uip_glue_init();
        serial_print("e1000: ");
        let i: int = 0;
        while (i < 6) {
            if (i > 0) {
                serial_putc(58);
            }
            print_byte_hex(my_mac[i]);
            i = i + 1;
        }
        serial_putc(10);
    } else {
        serial_print("e1000: not found\n");
    }
}
