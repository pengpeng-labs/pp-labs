/* wasm.pp：最小 WASM 解释器——W1 二进制解析（magic/version/sections + LEB128） */

/* 内存布局：wasm 模块 0x401400 起（≤4KB），运行栈 0x404000 起（2KB） */

/* ---- LEB128 ---- */

/* 读无符号 LEB128，返回值；pos 指向当前字节（in/out） */
fn wasm_uleb(src: int, pos: int) -> int {
    let result: int = 0;
    let shift: int = 0;
    let i: int = pos;
    while (true) {
        let b: int = volatile_load8(src + i);
        result = result | ((b & 127) << shift);
        if ((b & 128) == 0) {
            break;
        }
        shift = shift + 7;
        i = i + 1;
    }
    return result;
}

/* 读有符号 LEB128 */
fn wasm_sleb(src: int, pos: int) -> int {
    let result: int = 0;
    let shift: int = 0;
    let i: int = pos;
    let b: int = 0;
    while (true) {
        b = volatile_load8(src + i);
        result = result | ((b & 127) << shift);
        shift = shift + 7;
        i = i + 1;
        if ((b & 128) == 0) {
            break;
        }
    }
    if ((b & 64) != 0) {
        result = result | (0 - (1 << shift));
    }
    return result;
}

/* LEB128 跳过（返回新位置） */
fn wasm_skip_uleb(src: int, pos: int) -> int {
    let i: int = pos;
    while ((volatile_load8(src + i) & 128) != 0) {
        i = i + 1;
    }
    return i + 1;
}

/* 读名称（长度 + 字节），返回下一位置 */
fn wasm_skip_name(src: int, pos: int) -> int {
    let len: int = wasm_uleb(src, pos);
    let p: int = wasm_skip_uleb(src, pos);
    return p + len;
}

/* ---- 解析结果 ---- */
static wasm_type_count: int = 0;          /* 函数类型数 */
static wasm_type_params: [8]int;        /* 每类型参数数 */
static wasm_import_count: int = 0;        /* 导入数 */
static wasm_func_count: int = 0;          /* 函数总数（含导入） */
static wasm_code_count: int = 0;          /* 代码段函数体数 */
static wasm_code_off: [8]int;           /* 每个函数体的字节偏移 */
static wasm_code_len: [8]int;           /* 每个函数体长度 */
static wasm_mem_pages: int = 0;           /* 内存页数 */
static wasm_export_count: int = 0;

/* 解析 wasm 模块（src 指向二进制），返回 0 成功 / -1 失败 */
fn wasm_parse(src: int, len: int) -> int {
    wasm_type_count = 0;
    wasm_import_count = 0;
    wasm_func_count = 0;
    wasm_code_count = 0;
    wasm_mem_pages = 0;
    wasm_base = src;
    /* magic: \0asm */
    if (volatile_load8(src) != 0 || volatile_load8(src + 1) != 97
        || volatile_load8(src + 2) != 115 || volatile_load8(src + 3) != 109) {
        return -1;
    }
    /* version: 1 */
    if (volatile_load8(src + 4) != 1 || volatile_load8(src + 5) != 0
        || volatile_load8(src + 6) != 0 || volatile_load8(src + 7) != 0) {
        return -1;
    }
    let p: int = 8;
    while (p < len - 1) {
        let sid: int = volatile_load8(src + p);
        let slen: int = wasm_uleb(src, p + 1);
        let sp: int = wasm_skip_uleb(src, p + 1);
        let send: int = sp + slen;
        if (sid == 1) {
            /* type section：函数类型 */
            let t: int = sp;
            let n: int = wasm_uleb(src, t);
            let tp: int = wasm_skip_uleb(src, t);
            while (tp < send && wasm_type_count < 8) {
                let form: int = volatile_load8(src + tp);
                if (form != 0x60) {
                    return -1;
                }
                let np: int = wasm_uleb(src, tp + 1);
                let pp: int = wasm_skip_uleb(src, tp + 1);
                wasm_type_params[wasm_type_count] = np;
                wasm_type_count = wasm_type_count + 1;
                /* 跳过参数 + 结果 */
                let q: int = pp;
                let k: int = 0;
                while (k < np) {
                    q = q + 1;
                    k = k + 1;
                }
                let rn: int = wasm_uleb(src, q);
                q = wasm_skip_uleb(src, q);
                let k2: int = 0;
                while (k2 < rn) {
                    q = q + 1;
                    k2 = k2 + 1;
                }
                tp = q;
            }
        } else if (sid == 2) {
            /* import section */
            let t: int = sp;
            let n: int = wasm_uleb(src, t);
            let tp: int = wasm_skip_uleb(src, t);
            let k: int = 0;
            while (k < n && tp < send) {
                tp = wasm_skip_name(src, tp);   /* module */
                tp = wasm_skip_name(src, tp);   /* name */
                let kind: int = volatile_load8(src + tp);
                tp = tp + 1;
                if (kind == 0) {   /* func */
                    wasm_import_count = wasm_import_count + 1;
                    wasm_func_count = wasm_func_count + 1;
                    tp = wasm_skip_uleb(src, tp);   /* type index */
                } else if (kind == 2) {   /* memory */
                    tp = wasm_skip_uleb(src, tp);   /* limits */
                    if (volatile_load8(src + tp) == 0) {
                        wasm_mem_pages = wasm_uleb(src, tp + 1);
                        tp = wasm_skip_uleb(src, tp + 1);
                    } else {
                        tp = wasm_skip_uleb(src, tp + 1);
                        wasm_mem_pages = wasm_uleb(src, tp);
                        tp = wasm_skip_uleb(src, tp);
                    }
                } else {
                    tp = wasm_skip_uleb(src, tp);
                    if (kind == 1) {
                        tp = wasm_skip_uleb(src, tp);
                    }
                }
                k = k + 1;
            }
        } else if (sid == 3) {
            /* function section：函数 → 类型 */
            let t: int = sp;
            let n: int = wasm_uleb(src, t);
            let tp: int = wasm_skip_uleb(src, t);
            wasm_func_count = wasm_func_count + n;
            let k: int = 0;
            while (k < n) {
                tp = wasm_skip_uleb(src, tp);
                k = k + 1;
            }
        } else if (sid == 5) {
            /* memory section */
            let t: int = sp;
            let n: int = wasm_uleb(src, t);
            let tp: int = wasm_skip_uleb(src, t);
            if (n > 0) {
                if (volatile_load8(src + tp) == 0) {
                    wasm_mem_pages = wasm_uleb(src, tp + 1);
                } else {
                    tp = wasm_skip_uleb(src, tp + 1);
                    wasm_mem_pages = wasm_uleb(src, tp);
                }
            }
        } else if (sid == 7) {
            /* export section */
            let t: int = sp;
            let n: int = wasm_uleb(src, t);
            let tp: int = wasm_skip_uleb(src, t);
            wasm_export_count = n;
            let k: int = 0;
            while (k < n) {
                tp = wasm_skip_name(src, tp);
                tp = tp + 1;   /* kind */
                tp = wasm_skip_uleb(src, tp);   /* index */
                k = k + 1;
            }
        } else if (sid == 10) {
            /* code section：函数体 */
            let t: int = sp;
            let n: int = wasm_uleb(src, t);
            let tp: int = wasm_skip_uleb(src, t);
            let k: int = 0;
            while (k < n && wasm_code_count < 8) {
                let blen: int = wasm_uleb(src, tp);
                let bp: int = wasm_skip_uleb(src, tp);
                wasm_code_len[wasm_code_count] = blen;
                wasm_code_off[wasm_code_count] = bp;
                wasm_code_count = wasm_code_count + 1;
                tp = bp + blen;
                k = k + 1;
            }
        }
        p = send;
    }
    return 0;
}

/* 打印解析摘要（调试/验证） */
fn wasm_dump() {
    serial_print("wasm: types=");
    print_int(wasm_type_count);
    serial_print(" imports=");
    print_int(wasm_import_count);
    serial_print(" funcs=");
    print_int(wasm_func_count);
    serial_print(" code=");
    print_int(wasm_code_count);
    serial_print(" mem=");
    print_int(wasm_mem_pages);
    serial_print(" exports=");
    print_int(wasm_export_count);
    serial_putc(10);
}

/* ---- W2 解释器 ---- */
static wasm_mem: int = 0x405000;      /* wasm 线性内存 */
static wasm_base: int = 0;            /* 模块基址 */
static wasm_trace: int = 0;           /* 执行轨迹计数 */
static wasm_stack: [256]int;        /* 操作数栈 */
static wasm_sp: int = 0;              /* 栈顶索引 */
static wasm_locals: [64]int;        /* 局部变量（参数 + local） */
static wasm_localn: int = 0;

fn ws_push(v: int) {
    wasm_stack[wasm_sp] = v;
    wasm_sp = wasm_sp + 1;
}

fn ws_pop() -> int {
    wasm_sp = wasm_sp - 1;
    return wasm_stack[wasm_sp];
}

/* 运行函数 func（函数索引，跳过导入），参数从 a0 起，返回栈顶 */
fn wasm_run(func: int, a0: int, a1: int) -> int {
    let body: int = wasm_base + wasm_code_off[func];
    let bend: int = body + wasm_code_len[func];
    /* 读 local 声明数（本地变量向量） */
    let np: int = wasm_uleb(body, 0);
    let p: int = wasm_skip_uleb(body, 0);
    /* 初始化 locals：前 2 个为参数，其余为声明的 local（默认 0） */
    wasm_localn = 0;
    wasm_locals[0] = a0;
    wasm_locals[1] = a1;
    wasm_localn = 2;
    let nv: int = 0;
    while (nv < np) {
        let k: int = 0;
        let vcount: int = wasm_uleb(body, p);
        p = wasm_skip_uleb(body, p);
        while (k < vcount) {
            if (wasm_localn < 64) {
                wasm_locals[wasm_localn] = 0;
                wasm_localn = wasm_localn + 1;
            }
            k = k + 1;
        }
        nv = nv + 1;
    }
    wasm_sp = 0;
    wasm_trace = 0;
    let pc: int = p;
    let ret: int = 0;
    while (pc < bend) {
        let op: int = volatile_load8(body + pc);
        if (op == 0x41) {   /* i32.const */
            let v: int = wasm_sleb(body, pc + 1);
            /* 跳过 sleb（含最后字节） */
            let q: int = pc + 1;
            while ((volatile_load8(body + q) & 128) != 0) {
                q = q + 1;
            }
            pc = q + 1;
            ws_push(v);
        } else if (op == 0x20) {   /* local.get */
            let idx: int = wasm_uleb(body, pc + 1);
            pc = wasm_skip_uleb(body, pc + 1);
            ws_push(wasm_locals[idx]);
        } else if (op == 0x21) {   /* local.set */
            let idx: int = wasm_uleb(body, pc + 1);
            pc = wasm_skip_uleb(body, pc + 1);
            wasm_locals[idx] = ws_pop();
        } else if (op == 0x6a) {   /* i32.add */
            let b: int = ws_pop();
            let a: int = ws_pop();
            ws_push(a + b);
        pc = pc + 1;
        } else if (op == 0x6b) {   /* i32.sub */
            let b: int = ws_pop();
            let a: int = ws_pop();
            ws_push(a - b);
        pc = pc + 1;
        } else if (op == 0x6c) {   /* i32.mul */
            let b: int = ws_pop();
            let a: int = ws_pop();
            ws_push(a * b);
        pc = pc + 1;
        } else if (op == 0x71) {   /* i32.and */
            let b: int = ws_pop();
            let a: int = ws_pop();
            ws_push(a & b);
        pc = pc + 1;
        } else if (op == 0x72) {   /* i32.or */
            let b: int = ws_pop();
            let a: int = ws_pop();
            ws_push(a | b);
        pc = pc + 1;
        } else if (op == 0x73) {   /* i32.xor */
            let b: int = ws_pop();
            let a: int = ws_pop();
            ws_push(a ^ b);
        pc = pc + 1;
        } else if (op == 0x46) {   /* i32.eq */
            let b: int = ws_pop();
            let a: int = ws_pop();
            if (a == b) { ws_push(1); } else { ws_push(0); }
        pc = pc + 1;
        } else if (op == 0x47) {   /* i32.ne */
            let b: int = ws_pop();
            let a: int = ws_pop();
            if (a != b) { ws_push(1); } else { ws_push(0); }
        pc = pc + 1;
        } else if (op == 0x48) {   /* i32.lt_s */
            let b: int = ws_pop();
            let a: int = ws_pop();
            if (a < b) { ws_push(1); } else { ws_push(0); }
        pc = pc + 1;
        } else if (op == 0x4a) {   /* i32.gt_s */
            let b: int = ws_pop();
            let a: int = ws_pop();
            if (a > b) { ws_push(1); } else { ws_push(0); }
        pc = pc + 1;
        } else if (op == 0x0b) {   /* end */
            break;
        } else if (op == 0x10) {   /* call */
            let fidx: int = wasm_uleb(body, pc + 1);
            pc = wasm_skip_uleb(body, pc + 1);
            if (fidx < wasm_import_count) {
                /* 导入函数：fd_write（最小 WASI）——栈上依次为 fd, iovs, iovs_len, nwritten */
                if (fidx == 0) {
                    let nw: int = ws_pop();
                    let ilen: int = ws_pop();
                    let iovs: int = ws_pop();
                    let fd: int = ws_pop();
                    let p0: int = volatile_load32(wasm_mem + iovs);
                    let l0: int = volatile_load32(wasm_mem + iovs + 4);
                    let k: int = 0;
                    while (k < l0) {
                        serial_putc(volatile_load8(wasm_mem + p0 + k));
                        k = k + 1;
                    }
                    ws_push(0);   /* errno 0 */
                } else {
                    ws_push(0);
                }
            } else {
                ws_push(0);   /* 用户函数调用（简化不支持） */
            }
        } else if (op == 0x2d) {   /* i32.load（简化：无对齐/偏移） */
            let addr: int = ws_pop();
            ws_push(volatile_load32(wasm_mem + addr));
        pc = wasm_skip_uleb(body, pc + 1);   /* align */
        pc = wasm_skip_uleb(body, pc);       /* offset */
        } else if (op == 0x36) {   /* i32.store（简化：无对齐/偏移） */
            let val: int = ws_pop();
            let addr: int = ws_pop();
            volatile_store32(wasm_mem + addr, val);
        pc = wasm_skip_uleb(body, pc + 1);   /* align */
        pc = wasm_skip_uleb(body, pc);       /* offset */
        } else if (op == 0x3a) {   /* i32.store8 */
            let val: int = ws_pop();
            let addr: int = ws_pop();
            volatile_store8(wasm_mem + addr, val & 0xFF);
        pc = wasm_skip_uleb(body, pc + 1);   /* align */
        pc = wasm_skip_uleb(body, pc);       /* offset */
        } else if (op == 0x1a) {   /* drop */
            ws_pop();
            pc = pc + 1;
        } else if (op == 0x02 || op == 0x03) {   /* block/loop：跳 blocktype（1 字节 0x40 或 valtype） */
            pc = pc + 2;
        } else {
            /* 未知指令：停止 */
            serial_print("wasm: op ");
            print_hex(op);
            serial_print(" pc=");
            print_int(pc);
            serial_print(" bend=");
            print_int(bend);
            serial_putc(10);
            return 0;
        }
    }
    if (wasm_sp > 0) {
        ret = ws_pop();
    } else {
        ret = 0;
    }
    return ret;
}
