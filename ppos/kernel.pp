extern fn load_idt();
extern fn switch_context(old_sp_addr: int, new_sp: int);
extern fn make_context(stack_top: int, func: int) -> int;

import "fs.pp";
import "net.pp";
import "tls.pp";
import "json.pp";
import "agent.pp";
import "browser.pp";
import "app.pp";
import "mcp.pp";
import "wasm.pp";
import "../ppdb/db_core.pp";
import "../ppdb/host_ppos.pp";
import "../ppdb/host_file_ppos.pp";
import "../ppdb/db_sql_parse.pp";
import "../ppdb/db_sql_exec.pp";
import "../ppdb/db_kv.pp";
import "../ppdb/db_doc.pp";
import "../ppdb/db_tx.pp";
import "../ppdb/db_persist.pp";

/* 全局状态 */
static tick_count: int = 0;        /* 单调递增，供 uIP 时钟（pp_ticks）使用 */
static tick_dot: int = 0;          /* 打点计数（每 10 tick 复位，勿与 tick_count 混用） */
static heap_ptr: int = 0x1000000;   /* 堆从 16MB 开始 */
static kb_w: int = 0;               /* 键盘缓冲写指针 */
static kb_r: int = 0;               /* 键盘缓冲读指针 */
static line_len: int = 0;           /* 当前命令行长度 */
static hb_count: int = 0;           /* 心跳协程计数 */
static spin_lock_val: int = 0;      /* 自旋锁状态 */

/* 自旋锁（atomic_xchg + 自旋） */
fn spin_lock() {
    while (atomic_xchg(ptr_to_int(&spin_lock_val), 1) != 0) {
        /* 自旋 */
    }
}

fn spin_unlock() {
    volatile_store32(ptr_to_int(&spin_lock_val), 0);
}

/* 固定内存区域：键盘缓冲 0x400000，命令行缓冲 0x400200（各 256 字节） */

fn serial_putc(c: int) {
    outb(0x3F8, c);
}

fn serial_print(s: str) {
    let a: int = ptr_to_int(s);
    let i: int = 0;
    while (volatile_load8(a + i) != 0) {
        serial_putc(volatile_load8(a + i));
        i = i + 1;
    }
}

/* 比较地址 pa 处的字符串与字面量 s */
fn str_eq(pa: int, s: str) -> int {
    let pb: int = ptr_to_int(s);
    let i: int = 0;
    while (true) {
        let ca: int = volatile_load8(pa + i);
        let cb: int = volatile_load8(pb + i);
        if (ca != cb) {
            return 0;
        }
        if (ca == 0) {
            return 1;
        }
        i = i + 1;
    }
    return 0;
}

/* 判断 pa 处字符串是否以 s 开头 */
fn str_starts(pa: int, s: str) -> int {
    let pb: int = ptr_to_int(s);
    let i: int = 0;
    while (true) {
        let cb: int = volatile_load8(pb + i);
        if (cb == 0) {
            return 1;
        }
        if (volatile_load8(pa + i) != cb) {
            return 0;
        }
        i = i + 1;
    }
    return 0;
}

/* free-list allocator：块布局 [next:4][size:4][pad:8]（16B 头，数据区 16 对齐）；first-fit + 切分；kfree 头插回收 */
static heap_free: int = 0;   /* 空闲链表头 */

fn kmalloc(size: int) -> int {
    let req: int = size + 16;
    let prev: int = 0;
    let cur: int = heap_free;
    while (cur != 0) {
        let bsize: int = volatile_load32(cur + 4);
        if (bsize >= req) {
            /* 切分点对齐 16：rem 是剩余块的起始 */
            let rem: int = (cur + req + 15) & 0xFFFFFFF0;
            let remain: int = bsize - (rem - cur);
            if (remain >= 16) {
                let nxt: int = volatile_load32(cur);
                volatile_store32(rem, nxt);
                volatile_store32(rem + 4, remain);
                if (prev != 0) {
                    volatile_store32(prev, rem);
                } else {
                    heap_free = rem;
                }
            } else {
                let nxt: int = volatile_load32(cur);
                if (prev != 0) {
                    volatile_store32(prev, nxt);
                } else {
                    heap_free = nxt;
                }
            }
            volatile_store32(cur + 4, req);
            return cur + 16;
        }
        prev = cur;
        cur = volatile_load32(cur);
    }
    /* 无合适空闲块：从堆尾分配（16 对齐） */
    let p: int = (heap_ptr + 15) & 0xFFFFFFF0;
    heap_ptr = p + req;
    volatile_store32(p + 4, req);
    return p + 16;
}

/* 释放：块头插回空闲链表（暂不合并相邻块） */
fn kfree(p: int) {
    let blk: int = p - 16;
    volatile_store32(blk, heap_free);
    heap_free = blk;
}

/* 重映射 8259 PIC */
fn pic_remap() {
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20);
    outb(0xA1, 0x28);
    outb(0x21, 0x04);
    outb(0xA1, 0x02);
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    outb(0x21, 0xFC);
    outb(0xA1, 0xFF);
}

/* 定时器中断：每 10 tick 打印 '.'（打点用独立计数，不重置 tick_count） */
fn timer_handler() {
    outb(0x20, 0x20);
    tick_count = tick_count + 1;
    tick_dot = tick_dot + 1;
    if (tick_dot >= 10) {
        serial_putc(46);
        tick_dot = 0;
    }
}

/* PIT tick 导出（uIP 时钟用） */
fn tick_count_global() -> int {
    return tick_count;
}

/* 键盘扫描码 → ASCII */
fn scancode_to_ascii(sc: int) -> int {
    if (sc >= 0x02 && sc <= 0x0B) { return 48 + ((sc - 2 + 9) % 10); }  /* 1-0 数字行 */
    if (sc == 0x0C) { return 45; }   /* - */
    if (sc == 0x0D) { return 61; }   /* = */
    if (sc == 0x1E) { return 97; }
    if (sc == 0x30) { return 98; }
    if (sc == 0x2E) { return 99; }
    if (sc == 0x20) { return 100; }
    if (sc == 0x12) { return 101; }
    if (sc == 0x21) { return 102; }
    if (sc == 0x22) { return 103; }
    if (sc == 0x23) { return 104; }
    if (sc == 0x17) { return 105; }
    if (sc == 0x24) { return 106; }
    if (sc == 0x25) { return 107; }
    if (sc == 0x26) { return 108; }
    if (sc == 0x32) { return 109; }
    if (sc == 0x31) { return 110; }
    if (sc == 0x18) { return 111; }
    if (sc == 0x19) { return 112; }
    if (sc == 0x10) { return 113; }
    if (sc == 0x13) { return 114; }
    if (sc == 0x1F) { return 115; }
    if (sc == 0x14) { return 116; }
    if (sc == 0x16) { return 117; }
    if (sc == 0x2F) { return 118; }
    if (sc == 0x11) { return 119; }
    if (sc == 0x2D) { return 120; }
    if (sc == 0x15) { return 121; }
    if (sc == 0x2C) { return 122; }
    if (sc == 0x39) { return 32; }
    if (sc == 0x1C) { return 10; }
    if (sc == 0x0E) { return 8; }
    if (sc == 0x34) { return 46; }   /* . */
    return 0;
}

/* 键盘中断：读扫描码 → 入缓冲 */
fn keyboard_handler() {
    let sc: int = inb(0x60);
    if (sc < 128) {
        let c: int = scancode_to_ascii(sc);
        if (c != 0) {
            volatile_store8(0x400000 + kb_w, c);
            kb_w = (kb_w + 1) % 256;
        }
    }
    outb(0x20, 0x20);
}

/* 清空 VGA 屏幕 */
fn clear_screen() {
    let i: int = 0;
    while (i < 2000) {
        volatile_store16(0xB8000 + 2 * i, 0x0F20);
        i = i + 1;
    }
}

/* 从行缓冲 offset 处拷贝一个空白分隔参数到 buf（int 地址），返回下一参数偏移 */
fn parse_arg(start: int, buf: int) -> int {
    while (volatile_load8(0x400200 + start) == 32) {
        start = start + 1;
    }
    while (true) {
        let c: int = volatile_load8(0x400200 + start);
        if (c == 32 || c == 0) {
            volatile_store8(buf, 0);
            return start;
        }
        volatile_store8(buf, c);
        start = start + 1;
        buf = buf + 1;
    }
    return start;
}

/* ---- pp-db 命令（sql/db 注册为 app，shell 与 app run 共用） ---- */

/* sql <语句>：解析 + 执行（CREATE 免查找，DROP 由执行器处理） */
fn cmd_sql() {
    let rc: int = db_parse_sql(0x400200 + 4);
    if (rc < 0) {
        serial_print("sql: syntax error\n");
    } else if (db_stmt_is_create() || db_stmt_is_tx()) {
        db_exec(-1);
    } else {
        let tid: int = db_find_table(int_to_ptr(db_stmt_table));
        if (tid < 0) {
            serial_print("sql: no such table\n");
        } else {
            db_exec(tid);
        }
    }
}

/* db <子命令>：KV/Doc/表目录（create/drop/list）/ ask（NL→操作） */
fn cmd_db() {
    if (str_starts(0x400200, "db ask ") == 1) {
        /* db ask <问题>：LLM 看 schema → sql/kv/doc 工具操作 → 结果回传 + 会话落库 */
        db_ask(0x400200 + 7, line_len - 7);
    } else if (str_starts(0x400200, "db put ") == 1) {
        parse_arg(7, 0x400300);   /* key */
        let hp: int = 7;
        while (volatile_load8(0x400200 + hp) != 0 && volatile_load8(0x400200 + hp) != 32) {
            hp = hp + 1;
        }
        while (volatile_load8(0x400200 + hp) == 32) {
            hp = hp + 1;
        }
        if (kv_put(0x400300, 0x400200 + hp) == 1) {
            serial_print("kv put ok\n");
        } else {
            serial_print("kv full\n");
        }
    } else if (str_starts(0x400200, "db get ") == 1) {
        parse_arg(7, 0x400300);
        let gl: int = kv_get(0x400300, 0x400C00);
        if (gl >= 0) {
            serial_print("kv: ");
            let j: int = 0;
            while (j < gl) {
                serial_putc(volatile_load8(0x400C00 + j));
                j = j + 1;
            }
            serial_putc(10);
        } else {
            serial_print("kv: not found\n");
        }
    } else if (str_starts(0x400200, "db del ") == 1) {
        parse_arg(7, 0x400300);
        if (kv_del(0x400300) == 1) {
            serial_print("kv del ok\n");
        } else {
            serial_print("kv: not found\n");
        }
    } else if (str_starts(0x400200, "db doc put ") == 1) {
        parse_arg(11, 0x400300);   /* name */
        let hp: int = 11;
        while (volatile_load8(0x400200 + hp) != 0 && volatile_load8(0x400200 + hp) != 32) {
            hp = hp + 1;
        }
        while (volatile_load8(0x400200 + hp) == 32) {
            hp = hp + 1;
        }
        if (doc_put(0x400300, 0x400200 + hp) == 1) {
            serial_print("doc put ok\n");
        } else {
            serial_print("doc full\n");
        }
    } else if (str_starts(0x400200, "db doc get ") == 1) {
        parse_arg(11, 0x400300);
        let gl: int = doc_get(0x400300, 0x400C00);
        if (gl >= 0) {
            serial_print("doc: ");
            let j: int = 0;
            while (j < gl) {
                serial_putc(volatile_load8(0x400C00 + j));
                j = j + 1;
            }
            serial_putc(10);
        } else {
            serial_print("doc: not found\n");
        }
    } else if (str_starts(0x400200, "db save ") == 1) {
        parse_arg(8, 0x400300);
        db_save(0x400300);
    } else if (str_starts(0x400200, "db load ") == 1) {
        parse_arg(8, 0x400300);
        db_load(0x400300);
    } else if (str_eq(0x400200, "db list") == 1) {
        db_list();
    } else if (str_starts(0x400200, "db drop ") == 1) {
        parse_arg(8, 0x400300);
        let tid: int = db_find_table(int_to_ptr(0x400300));
        if (tid >= 0) {
            db_drop_table(tid);
            serial_print("table dropped\n");
        } else {
            serial_print("sql: no such table\n");
        }
    } else if (str_starts(0x400200, "db create ") == 1) {
        /* db create <name> <int|str> ...（≤4 列，简化版 CREATE） */
        let pos: int = parse_arg(10, 0x400300);   /* name → 0x400300 */
        let ct: [4]int;
        let cn: int = 0;
        while (cn < 4) {
            let pp: int = parse_arg(pos, 0x400400);
            if (volatile_load8(0x400400) == 0) {
                break;   /* 无更多类型 */
            }
            let t0: int = str_eq(0x400400, "int");
            if (t0 == 1) {
                ct[cn] = 0;
            } else {
                ct[cn] = 1;   /* 默认 str */
            }
            cn = cn + 1;
            pos = pp;
        }
        let r: int = db_create_table(int_to_ptr(0x400300), cn,
            ct[0], ct[1], ct[2], ct[3]);
        if (r >= 0) {
            serial_print("table created\n");
        } else {
            serial_print("create failed\n");
        }
    } else {
        serial_print("db: put/get/del/list/create/drop/save/load/ask | doc put/get\n");
    }
}

/* 处理命令行缓冲中的命令 */
fn process_line() {
    if (line_len == 0) {
        return;
    }
    if (str_eq(0x400200, "help") == 1) {
        serial_print("commands: help, ls, cat, write, rm, app list/run, db, sql, mcp, wasm, dns, https, run\n");
    } else if (str_eq(0x400200, "ls") == 1) {
        fs_list();
    } else if (str_starts(0x400200, "cat ") == 1) {
        parse_arg(4, 0x400300);
        let idx: int = fs_find(int_to_ptr(0x400300));
        if (idx >= 0) {
            fs_print(idx);
        } else {
            serial_print("no such file\n");
        }
    } else if (str_starts(0x400200, "rm ") == 1) {
        parse_arg(3, 0x400300);
        if (fs_remove(int_to_ptr(0x400300)) == 0) {
            serial_print("removed\n");
        } else {
            serial_print("no such file\n");
        }
    } else if (str_starts(0x400200, "write ") == 1) {
        let n: int = parse_arg(6, 0x400300);
        let idx: int = fs_find(int_to_ptr(0x400300));
        if (idx < 0) {
            idx = fs_create(int_to_ptr(0x400300));
        }
        if (idx >= 0) {
            parse_arg(n, 0x400400);
            fs_write(idx, int_to_ptr(0x400400));
            serial_print("ok\n");
        } else {
            serial_print("fs full\n");
        }
    } else if (str_eq(0x400200, "arp") == 1) {
        let target: [4]u8;
        target[0] = 10;
        target[1] = 0;
        target[2] = 2;
        target[3] = 2;   /* 网关 10.0.2.2 */
        arp_request(ptr_to_int(&target[0]));
        serial_print("arp sent\n");
        let tries: int = 0;
        while (tries < 2000) {
            if (net_poll() == 1) {
                tries = 2000;
            } else {
                tries = tries + 1;
            }
            hlt();
        }
    } else if (str_starts(0x400200, "dns ") == 1) {
        /* 先 ARP 解析网关 10.0.2.2 */
        let gw: [4]u8;
        gw[0] = 10;
        gw[1] = 0;
        gw[2] = 2;
        gw[3] = 2;
        arp_request(ptr_to_int(&gw[0]));
        let t: int = 0;
        while (t < 3000) {
            if (net_poll() == 1) {
                t = 3000;
            } else {
                t = t + 1;
            }
            hlt();
        }
        /* 发 DNS 查询（主机名在 "dns " 之后） */
        dns_query(int_to_ptr(0x400200 + 4));
        let t2: int = 0;
        while (t2 < 5000) {
            if (net_poll() == 1) {
                t2 = 5000;
            } else {
                t2 = t2 + 1;
            }
            hlt();
        }
    } else if (str_starts(0x400200, "https ") == 1) {
        /* 先 ARP 解析网关 */
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
        /* DNS 解析主机名（"https " 之后） */
        dns_query(int_to_ptr(0x400200 + 6));
        let ht2: int = 0;
        while (ht2 < 5000) {
            if (net_poll() == 1) {
                ht2 = 5000;
            } else {
                ht2 = ht2 + 1;
            }
            hlt();
        }
        /* HTTPS GET / */
        https_get(ptr_to_int(&dns_resolved[0]), 443, int_to_ptr(0x400200 + 6), "/");
    } else if (str_starts(0x400200, "ds ") == 1) {
        /* app: DeepSeek 对话 agent */
        ds_main();
    } else if (str_starts(0x400200, "browse ") == 1) {
        /* app: CLI 文本浏览器 */
        browse_main();
    } else if (str_eq(0x400200, "app list") == 1) {
        app_cmd_list();
    } else if (str_starts(0x400200, "app run ") == 1) {
        parse_arg(8, 0x400300);
        app_cmd_run(0x400300);
    } else if (str_starts(0x400200, "app help ") == 1) {
        parse_arg(9, 0x400300);
        app_cmd_help(0x400300);
    } else if (str_starts(0x400200, "mcp ") == 1) {
        /* MCP：JSON-RPC 请求直接测试（mcp <json> 或 mcp list/call ls 快捷方式） */
        if (str_eq(0x400200, "mcp list") == 1) {
            let reqs: str = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}";
            let ri: int = 0;
            while (reqs[ri] != 0) {
                volatile_store8(0x400900 + ri, reqs[ri]);
                ri = ri + 1;
            }
            volatile_store8(0x400900 + ri, 0);
            let rl: int = mcp_handle(0x400900, 0x400A00);
            serial_print("MCP: ");
            let j: int = 0;
            while (j < rl) {
                serial_putc(volatile_load8(0x400A00 + j));
                j = j + 1;
            }
        } else if (str_starts(0x400200, "mcp call ") == 1) {
            parse_arg(9, 0x400300);
            let tres: int = mcp_call(0x400300, 0, 0x400A00);
            serial_print("MCP call result: ");
            let j: int = 0;
            while (j < tres) {
                serial_putc(volatile_load8(0x400A00 + j));
                j = j + 1;
            }
            serial_putc(10);
        } else if (str_starts(0x400200, "mcp ") == 1) {
            /* 原始 JSON-RPC 请求（从 "mcp " 之后） */
            let rl: int = mcp_handle(0x400200 + 4, 0x400A00);
            serial_print("MCP: ");
            let j: int = 0;
            while (j < rl) {
                serial_putc(volatile_load8(0x400A00 + j));
                j = j + 1;
            }
        }
    } else if (str_starts(0x400200, "db ") == 1) {
        cmd_db();
    } else if (str_starts(0x400200, "sql ") == 1) {
        cmd_sql();
    } else if (str_starts(0x400200, "wasm install ") == 1) {
        /* 安装 WASM：wasm install <file> <hex>——hex 转二进制写入 FS */
        let hp0: int = parse_arg(13, 0x400300);   /* 返回分隔符位置 */
        let fname: int = 0x400300;
        let hp: int = hp0;
        while (volatile_load8(0x400200 + hp) == 32) {
            hp = hp + 1;
        }
        let idx: int = fs_find(int_to_ptr(fname));
        if (idx < 0) {
            idx = fs_create(int_to_ptr(fname));
        }
        if (idx >= 0) {
            /* hex → 二进制到 0x400C00 */
            let bi: int = 0;
            let hi2: int = hp;
            while (volatile_load8(0x400200 + hi2) != 0 && bi < 240) {
                let c1: int = volatile_load8(0x400200 + hi2);
                let c2: int = volatile_load8(0x400200 + hi2 + 1);
                let v1: int = 0;
                let v2: int = 0;
                if (c1 >= 48 && c1 <= 57) { v1 = c1 - 48; }
                else if (c1 >= 97 && c1 <= 102) { v1 = c1 - 87; }
                else if (c1 >= 65 && c1 <= 70) { v1 = c1 - 55; }
                if (c2 >= 48 && c2 <= 57) { v2 = c2 - 48; }
                else if (c2 >= 97 && c2 <= 102) { v2 = c2 - 87; }
                else if (c2 >= 65 && c2 <= 70) { v2 = c2 - 55; }
                volatile_store8(0x400C00 + bi, (v1 << 4) | v2);
                bi = bi + 1;
                hi2 = hi2 + 2;
            }
            fs_write_bin(idx, 0x400C00, bi);
            serial_print("wasm installed (");
            print_int(bi);
            serial_print(" bytes)\n");
        } else {
            serial_print("fs full\n");
        }
    } else if (str_starts(0x400200, "wasm run ") == 1) {
        /* 运行 WASM 文件：wasm run <file> */
        parse_arg(9, 0x400300);
        let widx: int = fs_find(int_to_ptr(0x400300));
        if (widx >= 0) {
            let wlen: int = fs_read(widx, 0x401400);
            let rc: int = wasm_parse(0x401400, wlen);
            if (rc == 0) {
                wasm_dump();
                let r: int = wasm_run(0, 0, 0);
                serial_print("wasm done rc=");
                print_int(r);
                serial_putc(10);
            } else {
                serial_print("wasm: bad module\n");
            }
        } else {
            serial_print("wasm: no such file\n");
        }
    } else if (str_eq(0x400200, "wasm test") == 1) {
        /* 内存构造 hello.wasm（import fd_write + 输出 "hi\n"）并运行 */
        let w: int = 0x401400;
                        let wb: [110]u8;
        wb[0]=0x00; wb[1]=0x61; wb[2]=0x73; wb[3]=0x6D; wb[4]=0x01;
        wb[5]=0x00; wb[6]=0x00; wb[7]=0x00; wb[8]=0x01; wb[9]=0x09;
        wb[10]=0x01; wb[11]=0x60; wb[12]=0x04; wb[13]=0x7F; wb[14]=0x7F;
        wb[15]=0x7F; wb[16]=0x7F; wb[17]=0x01; wb[18]=0x7F; wb[19]=0x02;
        wb[20]=0x11; wb[21]=0x01; wb[22]=0x04; wb[23]=0x77; wb[24]=0x61;
        wb[25]=0x73; wb[26]=0x69; wb[27]=0x08; wb[28]=0x66; wb[29]=0x64;
        wb[30]=0x5F; wb[31]=0x77; wb[32]=0x72; wb[33]=0x69; wb[34]=0x74;
        wb[35]=0x65; wb[36]=0x00; wb[37]=0x00; wb[38]=0x03; wb[39]=0x02;
        wb[40]=0x01; wb[41]=0x00; wb[42]=0x05; wb[43]=0x03; wb[44]=0x01;
        wb[45]=0x00; wb[46]=0x01; wb[47]=0x07; wb[48]=0x09; wb[49]=0x01;
        wb[50]=0x05; wb[51]=0x73; wb[52]=0x74; wb[53]=0x61; wb[54]=0x72;
        wb[55]=0x74; wb[56]=0x00; wb[57]=0x00; wb[58]=0x0A; wb[59]=0x32;
        wb[60]=0x01; wb[61]=0x30; wb[62]=0x00; wb[63]=0x41; wb[64]=0x00;
        wb[65]=0x41; wb[66]=0x68; wb[67]=0x3A; wb[68]=0x00; wb[69]=0x00;
        wb[70]=0x41; wb[71]=0x01; wb[72]=0x41; wb[73]=0x69; wb[74]=0x3A;
        wb[75]=0x00; wb[76]=0x00; wb[77]=0x41; wb[78]=0x02; wb[79]=0x41;
        wb[80]=0x0A; wb[81]=0x3A; wb[82]=0x00; wb[83]=0x00; wb[84]=0x41;
        wb[85]=0x10; wb[86]=0x41; wb[87]=0x00; wb[88]=0x36; wb[89]=0x02;
        wb[90]=0x00; wb[91]=0x41; wb[92]=0x14; wb[93]=0x41; wb[94]=0x03;
        wb[95]=0x36; wb[96]=0x02; wb[97]=0x00; wb[98]=0x41; wb[99]=0x01;
        wb[100]=0x41; wb[101]=0x10; wb[102]=0x41; wb[103]=0x01; wb[104]=0x41;
        wb[105]=0x18; wb[106]=0x10; wb[107]=0x00; wb[108]=0x1A; wb[109]=0x0B;
        let wj: int = 0;
        while (wj < 110) {
            volatile_store8(w + wj, wb[wj]);
            wj = wj + 1;
        }
        let rc: int = wasm_parse(w, 110);
        if (rc == 0) {
            wasm_dump();
            let r: int = wasm_run(0, 0, 0);
            serial_print("wasm done rc=");
            print_int(r);
            serial_putc(10);
        } else {
            serial_print("wasm: bad module\n");
        }
    } else if (str_starts(0x400200, "wasm ") == 1) {
        /* WASM：解析并运行 FS 中的 .wasm 模块（暂只有解析） */
        parse_arg(5, 0x400300);
        let widx: int = fs_find(int_to_ptr(0x400300));
        if (widx >= 0) {
            let wlen: int = fs_read(widx, 0x401400);
            let rc: int = wasm_parse(0x401400, wlen);
            if (rc == 0) {
                wasm_dump();
            } else {
                serial_print("wasm: bad module\n");
            }
        } else {
            serial_print("wasm: no such file\n");
        }
    } else if (str_starts(0x400200, "run ") == 1) {
        /* shell 脚本：从 FS 读取，逐行执行（忽略 # 注释与空行） */
        parse_arg(4, 0x400300);
        let ridx: int = fs_find(int_to_ptr(0x400300));
        if (ridx >= 0) {
            let rlen: int = fs_read(ridx, 0x400800);
            let li: int = 0;
            let ci: int = 0;
            while (ci <= rlen) {
                let ch: int = 0;
                if (ci < rlen) {
                    ch = volatile_load8(0x400800 + ci);
                }
                if (ch == 10 || ci == rlen) {   /* 换行或结束 */
                    let len2: int = ci - li;
                    if (len2 > 0) {
                        let k: int = 0;
                        while (k < len2 && k < 250) {
                            volatile_store8(0x400200 + k, volatile_load8(0x400800 + li + k));
                            k = k + 1;
                        }
                        volatile_store8(0x400200 + k, 0);
                        line_len = k;
                        let first: int = volatile_load8(0x400200);
                        if (first != 35 && first != 0) {   /* '#' 或空行 */
                            serial_putc(10);
                            process_line();
                        }
                    }
                    li = ci + 1;
                }
                ci = ci + 1;
            }
            serial_print("script done\n");
        } else {
            serial_print("no such script\n");
        }
    } else if (str_starts(0x400200, "app") == 1) {
        serial_print("apps: app list | app run <name> | app help <name>\n");
    } else if (str_starts(0x400200, "http") == 1) {
        /* 先 ARP 解析网关 10.0.2.2 */
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
        /* 发 HTTP GET（路径在 "http " 之后，连到 10.0.2.2:8000） */
        http_get(ptr_to_int(&gw[0]), 8000, int_to_ptr(0x400200 + 5));
    } else if (str_eq(0x400200, "about") == 1) {
        serial_print("pp-os: a unikernel written in pp-lang\n");
    } else if (str_eq(0x400200, "clear") == 1) {
        clear_screen();
    } else if (str_starts(0x400200, "echo") == 1) {
        let i: int = 5;
        while (i < line_len) {
            serial_putc(volatile_load8(0x400200 + i));
            i = i + 1;
        }
        serial_putc(10);
    } else {
        serial_print("unknown command: ");
        let i: int = 0;
        while (i < line_len) {
            serial_putc(volatile_load8(0x400200 + i));
            i = i + 1;
        }
        serial_putc(10);
    }
    line_len = 0;
}

/* 合作式 yield：切换到另一个协程 */
fn yield_() {
    let cur: int = volatile_load32(0x500010);
    let nxt: int = 1 - cur;
    volatile_store32(0x500010, nxt);
    switch_context(0x500000 + 8 * cur, volatile_load32(0x500000 + 8 * nxt));
}

/* 心跳协程：周期性打印 'H'，演示与 shell 并发 */
fn heartbeat() {
    while (true) {
        hb_count = hb_count + 1;
        if (hb_count >= 20) {
            serial_putc(72);   /* 'H' */
            hb_count = 0;
        }
        yield_();
    }
}

/* app: browse——CLI 文本浏览器（DNS → HTTP GET → HTML 文本渲染） */
/* app: ds——DeepSeek 对话 agent（多轮对话 + 工具调用） */
fn ds_main() {
    agent_chat(0x400200 + 3, line_len - 3);
}

fn browse_main() {
    /* 薄壳：web_fetch（库）→ html_to_text（库）→ 打印 */
    let off: int = web_fetch(int_to_ptr(0x400200 + 7));
    if (off > 0) {
        let tl: int = html_to_text(0x650000 + off, web_body_len, 0x654000);
        serial_print("--- page ---\n");
        let j: int = 0;
        while (j < tl && j < 1500) {
            serial_putc(volatile_load8(0x654000 + j));
            j = j + 1;
        }
        serial_putc(10);
        serial_print("--- end ---\n");
    } else {
        serial_print("browse: no response\n");
    }
}

/* 简单 shell：轮询键盘缓冲，行编辑 + 命令执行 */
fn shell() {
    serial_print("pp-os> ");
    while (true) {
        hlt();
        if (kb_r != kb_w) {
            let c: int = volatile_load8(0x400000 + kb_r);
            kb_r = (kb_r + 1) % 256;
            if (c == 10) {
                serial_putc(10);
                process_line();
                serial_print("pp-os> ");
            } else if (c == 8) {
                if (line_len > 0) {
                    line_len = line_len - 1;
                    serial_putc(8);
                    serial_putc(32);
                    serial_putc(8);
                }
            } else {
                volatile_store8(0x400200 + line_len, c);
                line_len = line_len + 1;
                volatile_store8(0x400200 + line_len, 0);
                serial_putc(c);
            }
        }
        yield_();
    }
}

/* 临时：autotest 辅助——把命令串装入行缓冲并执行 */
fn autotest_cmd(s: str) {
    let k: int = 0;
    while (s[k] != 0) {
        volatile_store8(0x400200 + k, s[k]);
        k = k + 1;
    }
    volatile_store8(0x400200 + k, 0);
    line_len = k;
    serial_putc(10);
    process_line();
}

fn kmain() -> int {
    serial_print("PP-OS\n");
    pic_remap();
    /* PIT 定时器：100Hz（1193182/100 = 11931 = 0x2E9B），让 hlt/轮询以 ~10ms 粒度工作 */
    outb(0x43, 0x36);
    outb(0x40, 0x9B);
    outb(0x40, 0x2E);
    sti();
    fs_init();
    net_init();
    /* 注册应用（id 与 app_dispatch 分支顺序一致） */
    app_register("browse", "CLI web browser (text render)");
    app_register("ds", "DeepSeek chat agent");
    app_register("sql", "SQL queries (CREATE/INSERT/SELECT/UPDATE/DELETE/DROP)");
    app_register("db", "pp-db console (put/get/del/list/create/drop/doc)");
    /* 注册 MCP 工具（id 与 mcp_run_tool 分支一致） */
    mcp_register("ls", "List files in the pp-os file system");
    mcp_register("sql", "Execute SQL (CREATE/INSERT/SELECT/UPDATE/DELETE/DROP) against pp-db; param: sql");
    mcp_register("kv", "Key-value store ops; params: op (get/put/del), key, value");
    mcp_register("doc", "JSON document store ops; params: op (get/put), name, content");

    /* 临时：P15-1 验证 autotest（完整 db ask：需网络） */
    autotest_cmd("db create notes int str");
    autotest_cmd("sql INSERT INTO notes (id,msg) VALUES (1,'hello')");
    autotest_cmd("sql INSERT INTO notes (id,msg) VALUES (2,'world')");
    autotest_cmd("db ask First list all rows in the notes table. Then store key task1 with value done in the kv store. Then save a document named report with content finished.");
    autotest_cmd("db list");
    autotest_cmd("sql SELECT id,role,content FROM messages");
    autotest_cmd("db get msgid");
    autotest_cmd("db get lastq");
    autotest_cmd("db doc get session");
    serial_print("AUTOTEST DONE\n");

    /* 建立心跳协程（协程 1）；shell 是协程 0，跑在主栈上 */
    let stack: int = kmalloc(4096) + 4096;
    volatile_store32(0x500008, make_context(stack, &heartbeat));
    volatile_store32(0x500010, 0);
    shell();
    return 0;
}
