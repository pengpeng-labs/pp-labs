/* Shell, demo task and application policy. */

/* 全局状态 */
static line_len: int = 0;           /* 当前命令行长度 */
static hb_count: int = 0;           /* 心跳协程计数 */
static shell_mcp_request: [4096]u8;
static shell_mcp_response: [4096]u8;
static shell_log_snapshot: [4096]u8;
static db_app_token: [256]u8;
static db_app_value: [256]u8;
static db_app_output: [512]u8;

/* 固定内存区域：键盘缓冲 0x400000，命令行缓冲 0x400200（各 256 字节） */

/* 比较地址 pa 处的字符串与字面量 s */
fn str_eq(pa: u64, s: str) -> int {
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
fn str_starts(pa: u64, s: str) -> int {
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

/* ---- pp-db Native App frontend ---- */

fn app_parse_token(source: u64, size: int, start: int,
    destination: u64, capacity: int) -> int {
    while (start < size && volatile_load8(source + start) == 32) {
        start = start + 1;
    }
    let written: int = 0;
    while (start < size && volatile_load8(source + start) != 32) {
        if (written + 1 >= capacity) {
            volatile_store8(destination, 0);
            return -1;
        }
        volatile_store8(destination + written, volatile_load8(source + start));
        written = written + 1;
        start = start + 1;
    }
    volatile_store8(destination + written, 0);
    return start;
}

fn app_skip_spaces(source: u64, size: int, start: int) -> int {
    while (start < size && volatile_load8(source + start) == 32) {
        start = start + 1;
    }
    return start;
}

fn db_command(source: u64, size: int) -> int {
    let token: u64 = ptr_to_int(&db_app_token[0]);
    let scratch: u64 = ptr_to_int(&db_app_value[0]);
    let output: u64 = ptr_to_int(&db_app_output[0]);
    if (size >= 4 && str_starts(source, "ask ") == 1) {
        db_ask(source + 4, size - 4);
        return 0;
    } else if (size >= 4 && str_starts(source, "put ") == 1) {
        let next: int = app_parse_token(source, size, 4, token, 256);
        if (next < 0) { return 2; }
        let value_start: int = app_skip_spaces(source, size, next);
        if (value_start >= size) { return 2; }
        if (database_kv_write(token, source + value_start)) {
            console_write("kv put ok\n");
            return 0;
        }
        console_write("kv full\n");
        return 1;
    } else if (size >= 4 && str_starts(source, "get ") == 1) {
        if (app_parse_token(source, size, 4, token, 256) < 0) { return 2; }
        let value: ServiceBytes = database_kv_read(token, output);
        if (value.ok) {
            console_write("kv: ");
            console_write_bytes(value.data, value.len);
            console_putc(10);
            return 0;
        }
        console_write("kv: not found\n");
        return 1;
    } else if (size >= 4 && str_starts(source, "del ") == 1) {
        if (app_parse_token(source, size, 4, token, 256) < 0) { return 2; }
        if (database_kv_remove(token)) {
            console_write("kv del ok\n");
            return 0;
        }
        console_write("kv: not found\n");
        return 1;
    } else if (size >= 8 && str_starts(source, "doc put ") == 1) {
        let next: int = app_parse_token(source, size, 8, token, 256);
        if (next < 0) { return 2; }
        let content_start: int = app_skip_spaces(source, size, next);
        if (content_start >= size) { return 2; }
        if (database_doc_write(token, source + content_start)) {
            console_write("doc put ok\n");
            return 0;
        }
        console_write("doc full\n");
        return 1;
    } else if (size >= 8 && str_starts(source, "doc get ") == 1) {
        if (app_parse_token(source, size, 8, token, 256) < 0) { return 2; }
        let document: ServiceBytes = database_doc_read(token, output);
        if (document.ok) {
            console_write("doc: ");
            console_write_bytes(document.data, document.len);
            console_putc(10);
            return 0;
        }
        console_write("doc: not found\n");
        return 1;
    } else if (size >= 5 && str_starts(source, "save ") == 1) {
        if (app_parse_token(source, size, 5, token, 256) < 0) { return 2; }
        database_save(token);
        return 0;
    } else if (size >= 5 && str_starts(source, "load ") == 1) {
        if (app_parse_token(source, size, 5, token, 256) < 0) { return 2; }
        database_load(token);
        return 0;
    } else if (str_eq(source, "list") == 1) {
        database_list();
        return 0;
    } else if (size >= 5 && str_starts(source, "drop ") == 1) {
        if (app_parse_token(source, size, 5, token, 256) < 0) { return 2; }
        let table: DbTableHandle = database_table(token);
        if (database_drop(table)) {
            console_write("table dropped\n");
            return 0;
        }
        console_write("sql: no such table\n");
        return 1;
    } else if (size >= 7 && str_starts(source, "create ") == 1) {
        let pos: int = app_parse_token(source, size, 7, token, 256);
        if (pos < 0 || volatile_load8(token) == 0) { return 2; }
        let ct: [4]int;
        let cn: int = 0;
        while (cn < 4) {
            let next: int = app_parse_token(source, size, pos, scratch, 256);
            if (next < 0) { return 2; }
            if (volatile_load8(scratch) == 0) { break; }
            if (str_eq(scratch, "int") == 1) { ct[cn] = 0; }
            else { ct[cn] = 1; }
            cn = cn + 1;
            pos = next;
        }
        let table: DbTableHandle = database_create(token, cn,
            ct[0], ct[1], ct[2], ct[3]);
        if (database_table_is_valid(table)) {
            console_write("table created\n");
            return 0;
        }
        console_write("create failed\n");
        return 1;
    }
    console_write("db: put/get/del/list/create/drop/save/load/ask | doc put/get\n");
    return 2;
}

/* 处理命令行缓冲中的命令 */
fn process_line() {
    if (line_len == 0) {
        return;
    }
    if (str_eq(0x400200, "panic") == 1) {
        trigger_invalid_opcode();
    } else if (str_eq(0x400200, "help") == 1) {
        console_write("commands: help, panic, log, ls, cat, write, rm, app list/run, db, sql, mcp, wasm, dns, https, run\n");
    } else if (str_eq(0x400200, "log") == 1) {
        /* Temporary R2 reader; R4 Log Pane will keep a persistent cursor. */
        let cursor: KernelLogCursor = kernel_log_cursor_oldest();
        let count: int = kernel_log_read(&cursor, ptr_to_int(&shell_log_snapshot[0]), 4096);
        console_write("KLOG SNAPSHOT BEGIN\n");
        if (cursor.lost > (0 as u64)) {
            console_write("[older log bytes overwritten]\n");
        }
        if (count > 0) {
            console_write_bytes(ptr_to_int(&shell_log_snapshot[0]), count);
        }
        console_write("\nKLOG SNAPSHOT END\n");
    } else if (str_eq(0x400200, "ls") == 1) {
        file_list();
    } else if (str_starts(0x400200, "cat ") == 1) {
        parse_arg(4, 0x400300);
        let file: FileHandle = file_open(int_to_ptr(0x400300));
        if (file_print(file)) {
        } else {
            console_write("no such file\n");
        }
    } else if (str_starts(0x400200, "rm ") == 1) {
        parse_arg(3, 0x400300);
        if (file_remove(int_to_ptr(0x400300))) {
            console_write("removed\n");
        } else {
            console_write("no such file\n");
        }
    } else if (str_starts(0x400200, "write ") == 1) {
        let n: int = parse_arg(6, 0x400300);
        let file: FileHandle = file_open_or_create(int_to_ptr(0x400300));
        if (file_is_valid(file)) {
            parse_arg(n, 0x400400);
            file_write_text(file, int_to_ptr(0x400400));
            console_write("ok\n");
        } else {
            console_write("fs full\n");
        }
    } else if (str_eq(0x400200, "arp") == 1) {
        let target: [4]u8;
        target[0] = 10;
        target[1] = 0;
        target[2] = 2;
        target[3] = 2;   /* 网关 10.0.2.2 */
        arp_request(ptr_to_int(&target[0]));
        console_write("arp sent\n");
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
        app_cmd_run(ptr_to_int("ds"), (0x400200 + 3) as u64, line_len - 3);
    } else if (str_starts(0x400200, "browse ") == 1) {
        app_cmd_run(ptr_to_int("browse"), (0x400200 + 7) as u64, line_len - 7);
    } else if (str_eq(0x400200, "app list") == 1) {
        app_cmd_list();
    } else if (str_starts(0x400200, "app run ") == 1) {
        let args_start: int = parse_arg(8, 0x400300);
        while (args_start < line_len && volatile_load8(0x400200 + args_start) == 32) {
            args_start = args_start + 1;
        }
        app_cmd_run(0x400300, (0x400200 + args_start) as u64, line_len - args_start);
    } else if (str_starts(0x400200, "app help ") == 1) {
        parse_arg(9, 0x400300);
        app_cmd_help(0x400300);
    } else if (str_starts(0x400200, "mcp ") == 1) {
        /* MCP：JSON-RPC 请求直接测试（mcp <json> 或 mcp list/call ls 快捷方式） */
        if (str_eq(0x400200, "mcp list") == 1) {
            let reqs: str = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}";
            let request: BoundedWriter = writer_new(ptr_to_int(&shell_mcp_request[0]), 4096);
            writer_write_str(&request, reqs);
            writer_terminate(&request);
            let response: u64 = ptr_to_int(&shell_mcp_response[0]);
            let rl: int = mcp_handle(request.data, response, 4096);
            console_write("MCP: ");
            if (rl >= 0) { console_write_bytes(response, rl); }
        } else if (str_starts(0x400200, "mcp call ") == 1) {
            parse_arg(9, 0x400300);
            let response: u64 = ptr_to_int(&shell_mcp_response[0]);
            let tres: int = mcp_call(0x400300, 0, response, 4096);
            console_write("MCP call result: ");
            if (tres >= 0) { console_write_bytes(response, tres); }
            console_putc(10);
        } else if (str_starts(0x400200, "mcp ") == 1) {
            /* 原始 JSON-RPC 请求（从 "mcp " 之后） */
            let response: u64 = ptr_to_int(&shell_mcp_response[0]);
            let rl: int = mcp_handle((0x400200 + 4) as u64, response, 4096);
            console_write("MCP: ");
            if (rl >= 0) { console_write_bytes(response, rl); }
        }
    } else if (str_starts(0x400200, "db ") == 1) {
        app_cmd_run(ptr_to_int("db"), (0x400200 + 3) as u64, line_len - 3);
    } else if (str_eq(0x400200, "db") == 1) {
        app_cmd_run(ptr_to_int("db"), 0 as u64, 0);
    } else if (str_starts(0x400200, "sql ") == 1) {
        app_cmd_run(ptr_to_int("sql"), (0x400200 + 4) as u64, line_len - 4);
    } else if (str_eq(0x400200, "sql") == 1) {
        app_cmd_run(ptr_to_int("sql"), 0 as u64, 0);
    } else if (str_starts(0x400200, "wasm install ") == 1) {
        /* 安装 WASM：wasm install <file> <hex>——hex 转二进制写入 FS */
        let hp0: int = parse_arg(13, 0x400300);   /* 返回分隔符位置 */
        let fname: int = 0x400300;
        let hp: int = hp0;
        while (volatile_load8(0x400200 + hp) == 32) {
            hp = hp + 1;
        }
        let file: FileHandle = file_open_or_create(int_to_ptr(fname));
        if (file_is_valid(file)) {
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
            file_write_bytes(file, 0x400C00 as u64, bi);
            console_write("wasm installed (");
            print_int(bi);
            console_write(" bytes)\n");
        } else {
            console_write("fs full\n");
        }
    } else if (str_starts(0x400200, "wasm run ") == 1) {
        /* 运行 WASM 文件：wasm run <file> */
        parse_arg(9, 0x400300);
        let wasm_file: FileHandle = file_open(int_to_ptr(0x400300));
        if (file_is_valid(wasm_file)) {
            let wlen: int = file_read_all(wasm_file, 0x401400 as u64);
            let rc: int = wasm_parse(0x401400, wlen);
            if (rc == 0) {
                wasm_dump();
                let r: int = wasm_run(0, 0, 0);
                console_write("wasm done rc=");
                print_int(r);
                console_putc(10);
            } else {
                console_write("wasm: bad module\n");
            }
        } else {
            console_write("wasm: no such file\n");
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
            console_write("wasm done rc=");
            print_int(r);
            console_putc(10);
        } else {
            console_write("wasm: bad module\n");
        }
    } else if (str_starts(0x400200, "wasm ") == 1) {
        /* WASM：解析并运行 FS 中的 .wasm 模块（暂只有解析） */
        parse_arg(5, 0x400300);
        let wasm_file: FileHandle = file_open(int_to_ptr(0x400300));
        if (file_is_valid(wasm_file)) {
            let wlen: int = file_read_all(wasm_file, 0x401400 as u64);
            let rc: int = wasm_parse(0x401400, wlen);
            if (rc == 0) {
                wasm_dump();
            } else {
                console_write("wasm: bad module\n");
            }
        } else {
            console_write("wasm: no such file\n");
        }
    } else if (str_starts(0x400200, "run ") == 1) {
        /* shell 脚本：从 FS 读取，逐行执行（忽略 # 注释与空行） */
        parse_arg(4, 0x400300);
        let script_file: FileHandle = file_open(int_to_ptr(0x400300));
        if (file_is_valid(script_file)) {
            let rlen: int = file_read_all(script_file, 0x400800 as u64);
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
                            console_putc(10);
                            process_line();
                        }
                    }
                    li = ci + 1;
                }
                ci = ci + 1;
            }
            console_write("script done\n");
        } else {
            console_write("no such script\n");
        }
    } else if (str_starts(0x400200, "app") == 1) {
        console_write("apps: app list | app run <name> | app help <name>\n");
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
        console_write("pp-os: a unikernel written in pp-lang\n");
    } else if (str_eq(0x400200, "clear") == 1) {
        clear_screen();
    } else if (str_starts(0x400200, "echo") == 1) {
        let i: int = 5;
        while (i < line_len) {
            console_putc(volatile_load8(0x400200 + i));
            i = i + 1;
        }
        console_putc(10);
    } else {
        console_write("unknown command: ");
        let i: int = 0;
        while (i < line_len) {
            console_putc(volatile_load8(0x400200 + i));
            i = i + 1;
        }
        console_putc(10);
    }
    line_len = 0;
}

/* 心跳协程：周期性打印 'H'，演示与 shell 并发 */
fn heartbeat(argument: u64) -> int {
    if (argument != (0 as u64)) {
        return -1;
    }
    while (true) {
        hb_count = hb_count + 1;
        if (hb_count >= 20) {
            console_putc(72);   /* 'H' */
            hb_count = 0;
        }
        task_yield();
    }
    return 0;
}

/* app: browse——CLI 文本浏览器（DNS → HTTP GET → HTML 文本渲染） */
/* app: ds——DeepSeek 对话 agent（多轮对话 + 工具调用） */
fn ds_main(message: u64, message_len: int) {
    agent_chat(message, message_len);
}

fn ds_app_entry(context: *AppContext) -> int {
    let args: str = context.args;
    ds_main(ptr_to_int(args), len(args) as int);
    return 0;
}

fn browse_main(host: str) {
    /* 薄壳：web service → text renderer → console service。 */
    let response: ServiceBytes = web_fetch(host);
    let page: ServiceBytes = web_render_text(response);
    if (page.ok) {
        console_write("--- page ---\n");
        let shown: int = page.len;
        if (shown > 1500) {
            shown = 1500;
        }
        console_write_bytes(page.data, shown);
        console_putc(10);
        console_write("--- end ---\n");
    } else {
        console_write("browse: no response\n");
    }
}

fn browse_app_entry(context: *AppContext) -> int {
    if (len(context.args) == (0 as u64)) {
        console_write("browse app: host required\n");
        return 1;
    }
    browse_main(context.args);
    return 0;
}

fn sql_app_entry(context: *AppContext) -> int {
    let args: str = context.args;
    if (len(args) == (0 as u64)) {
        console_write("sql app: use app run sql <statement>\n");
        return 0;
    }
    if (database_execute_console(ptr_to_int(args))) {
        return 0;
    }
    return 1;
}

fn db_app_entry(context: *AppContext) -> int {
    let args: str = context.args;
    return db_command(ptr_to_int(args), len(args) as int);
}

fn shell_app_entry(context: *AppContext) -> int {
    if (len(context.args) != (0 as u64)) {
        return 2;
    }
    shell();
    return 0;
}

/* 简单 shell：轮询键盘缓冲，行编辑 + 命令执行 */
fn shell() {
    console_write("pp-os> ");
    while (true) {
        hlt();
        let c: int = input_read();
        if (c >= 0) {
            if (c == 10) {
                console_putc(10);
                process_line();
                console_write("pp-os> ");
            } else if (c == 8) {
                if (line_len > 0) {
                    line_len = line_len - 1;
                    console_putc(8);
                    console_putc(32);
                    console_putc(8);
                }
            } else {
                volatile_store8(0x400200 + line_len, c);
                line_len = line_len + 1;
                volatile_store8(0x400200 + line_len, 0);
                console_putc(c);
            }
        }
        task_yield();
    }
}
