/* cli.pp：pp-db 宿主机 CLI（独立分发入口）——REPL + 管道批处理
   用法：
     pp obj cli.pp && cc cli.o -o ppdb
     ./ppdb                 交互式（sql> / kv> / doc>）
     echo "sql ..." | ./ppdb  批处理（逐行执行）
   命令：sql <SQL>（CREATE/INSERT/SELECT 最小子集）、kv get|put|del、doc get|put、
         save <file>、load <file>、tables、quit
   说明：SQL 最小解析直接调 db_core API（宿主无关）；完整 SQL 解析器
   （db_sql_parse）依赖 pp-os 固定内存布局，仅供内核。 */

import "db_core.pp";
import "db_kv.pp";
import "db_doc.pp";
import "db_persist.pp";
import "host_native.pp";
import "host_file_native.pp";

extern fn putchar(c: int) -> int;
extern fn getchar() -> int;

fn serial_putc(c: int) {
    putchar(c);
}

fn serial_print(s: str) {
    let a: u64 = ptr_to_int(s);
    let i: int = 0;
    while (volatile_load8(a + i) != 0) {
        serial_putc(volatile_load8(a + i));
        i = i + 1;
    }
}

fn print_int(n: int) {
    if (n == 0) {
        serial_putc(48);
        return;
    }
    let buf: [12]u8;
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

/* 字符串前缀比较：buf 指向文本，s 是字面量 */
fn cli_starts(buf: u64, s: str) -> int {
    let i: int = 0;
    while (s[i] != 0) {
        if (volatile_load8(buf + i) != s[i]) {
            return 0;
        }
        i = i + 1;
    }
    return 1;
}

/* 字符串相等比较（buf 与字面量；s 结束即判定） */
fn str_eq(buf: u64, s: str) -> int {
    let i: int = 0;
    while (1) {
        let a: int = volatile_load8(buf + i);
        let b: int = s[i];
        if (b == 0) {
            if (a == 0) {
                return 1;
            }
            return 0;
        }
        if (a != b) {
            return 0;
        }
        i = i + 1;
    }
}

/* 提取第 k 个空白分隔参数到 out（拷贝），返回 1 有 */
fn cli_arg(buf: u64, k: int, out: u64) -> int {
    let pos: int = 0;
    let cur: int = 0;
    while (1) {
        while (volatile_load8(buf + pos) == 32 || volatile_load8(buf + pos) == 9
               || volatile_load8(buf + pos) == 10 || volatile_load8(buf + pos) == 13) {
            pos = pos + 1;
        }
        if (volatile_load8(buf + pos) == 0) {
            return 0;
        }
        if (cur == k) {
            let o: int = 0;
            while (volatile_load8(buf + pos) != 0 && volatile_load8(buf + pos) != 32
                   && volatile_load8(buf + pos) != 10 && volatile_load8(buf + pos) != 13) {
                volatile_store8(out + o, volatile_load8(buf + pos));
                o = o + 1;
                pos = pos + 1;
            }
            volatile_store8(out + o, 0);
            return 1;
        }
        cur = cur + 1;
        while (volatile_load8(buf + pos) != 0 && volatile_load8(buf + pos) != 32
               && volatile_load8(buf + pos) != 10 && volatile_load8(buf + pos) != 13) {
            pos = pos + 1;
        }
    }
    return 0;
}

/* 找关键字（空白分隔 token）并返回其后位置；找不到 -1 */
fn kw_find(buf: u64, kw: str) -> int {
    let pos: int = 0;
    while (volatile_load8(buf + pos) != 0) {
        while (volatile_load8(buf + pos) == 32 || volatile_load8(buf + pos) == 10
               || volatile_load8(buf + pos) == 13) {
            pos = pos + 1;
        }
        if (volatile_load8(buf + pos) == 0) {
            return -1;
        }
        let k: int = 0;
        let ok: int = 1;
        while (kw[k] != 0) {
            let c: int = volatile_load8(buf + pos + k);
            if (c >= 97 && c <= 122) {
                c = c - 32;   /* 大写化比较 */
            }
            let kc: int = kw[k];
            if (kc >= 97 && kc <= 122) {
                kc = kc - 32;
            }
            if (c != kc) {
                ok = 0;
                break;
            }
            k = k + 1;
        }
        if (ok == 1) {
            let c2: int = volatile_load8(buf + pos + k);
            if (c2 == 32 || c2 == 0 || c2 == 10 || c2 == 13) {
                return pos + k;
            }
        }
        while (volatile_load8(buf + pos) != 0 && volatile_load8(buf + pos) != 32
               && volatile_load8(buf + pos) != 10 && volatile_load8(buf + pos) != 13) {
            pos = pos + 1;
        }
    }
    return -1;
}

/* 大小写不敏感 token 匹配（buf 与字面量）：
   字面量 s 结束后，buf 处必须是分隔符（空格/逗号/(/)/\0）才算匹配——
   SQLite 词法器语义：避免 "int" 误匹配 "intx" */
fn ci_eq(buf: u64, s: str) -> int {
    let i: int = 0;
    while (1) {
        let a: int = volatile_load8(buf + i);
        if (a >= 97 && a <= 122) {
            a = a - 32;
        }
        let b: int = s[i];
        if (b >= 97 && b <= 122) {
            b = b - 32;
        }
        if (b == 0) {
            /* s 结束：buf 处必须是分隔符 */
            if (a == 0 || a == 32 || a == 44 || a == 40 || a == 41) {
                return 1;
            }
            return 0;
        }
        if (a != b) {
            return 0;
        }
        i = i + 1;
    }
}

/* 复制文本段（len 字节）到 out，补 0 */
fn copy_n(src: u64, len: int, out: u64) {
    let i: int = 0;
    while (i < len) {
        volatile_store8(out + i, volatile_load8(src + i));
        i = i + 1;
    }
    volatile_store8(out + len, 0);
}

/* ---- 最小 SQL 执行（宿主无关，直接调 db_core API）---- */

/* CREATE TABLE name (c0 TYPE, c1 TYPE, ...) —— 类型按位置，名字忽略 */
fn sql_create(sql: u64) -> int {
    let after: int = kw_find(sql, "TABLE");
    if (after < 0) {
        return 0;
    }
    let tname: [32]u8;
    let p: int = after;
    while (volatile_load8(sql + p) == 32) {
        p = p + 1;
    }
    let tn: int = 0;
    while (volatile_load8(sql + p) != 32 && volatile_load8(sql + p) != 40
           && volatile_load8(sql + p) != 0 && tn < 31) {
        tname[tn] = volatile_load8(sql + p);
        tn = tn + 1;
        p = p + 1;
    }
    tname[tn] = 0;
    /* 找列类型：int/str 出现次数 */
    let ncols: int = 0;
    let t0: int = 1;
    let t1: int = 1;
    let t2: int = 1;
    let t3: int = 1;
    let q: int = 0;
    while (q < 512) {
        let c: int = volatile_load8(sql + q);
        if (c == 0) {
            break;
        }
        if (ci_eq(sql + q, "int") == 1) {
            if (ncols == 0) {
                t0 = 0;
            } else if (ncols == 1) {
                t1 = 0;
            } else if (ncols == 2) {
                t2 = 0;
            } else {
                t3 = 0;
            }
            ncols = ncols + 1;
        } else if (ci_eq(sql + q, "str") == 1) {
            ncols = ncols + 1;
        }
        q = q + 1;
    }
    if (ncols < 1) {
        return 0;
    }
    let tid: int = db_create_table(int_to_ptr(ptr_to_int(&tname[0])), ncols, t0, t1, t2, t3);
    if (tid >= 0) {
        serial_print("table created\n");
    } else {
        serial_print("create failed\n");
    }
    return 1;
}

/* INSERT INTO name (...) VALUES (v1,v2) —— 值：数字或 'str'（无引号原样） */
fn sql_insert(sql: u64) -> int {
    let p1: int = kw_find(sql, "INTO");
    let p2: int = kw_find(sql, "VALUES");
    if (p1 < 0 || p2 < 0) {
        return 0;
    }
    let tname: [32]u8;
    let p: int = p1;
    while (volatile_load8(sql + p) == 32) {
        p = p + 1;
    }
    let tn: int = 0;
    while (volatile_load8(sql + p) != 32 && volatile_load8(sql + p) != 40
           && volatile_load8(sql + p) != 0 && tn < 31) {
        tname[tn] = volatile_load8(sql + p);
        tn = tn + 1;
        p = p + 1;
    }
    tname[tn] = 0;
    let tid: int = db_find_table(int_to_ptr(ptr_to_int(&tname[0])));
    if (tid < 0) {
        serial_print("sql: no such table\n");
        return 1;
    }
    /* 解析 VALUES (...) 内的值（最多 4 个） */
    let vals: [4]u64;
    let vi: int = 0;
    let q: int = p2;
    /* 跳到 '(' */
    while (volatile_load8(sql + q) != 40 && volatile_load8(sql + q) != 0) {
        q = q + 1;
    }
    if (volatile_load8(sql + q) != 40) {
        return 0;
    }
    q = q + 1;
    while (vi < 4 && volatile_load8(sql + q) != 41 && volatile_load8(sql + q) != 0) {
        while (volatile_load8(sql + q) == 32 || volatile_load8(sql + q) == 44) {
            q = q + 1;
        }
        let c: int = volatile_load8(sql + q);
        if (c == 39) {   /* ' 字符串 */
            q = q + 1;
            let sbuf: [32]u8;
            let si: int = 0;
            while (volatile_load8(sql + q) != 39 && volatile_load8(sql + q) != 0 && si < 31) {
                sbuf[si] = volatile_load8(sql + q);
                si = si + 1;
                q = q + 1;
            }
            sbuf[si] = 0;
            vals[vi] = ptr_to_int(&sbuf[0]);
            q = q + 1;
        } else if (c >= 48 && c <= 57) {
            let num: int = 0;
            while (volatile_load8(sql + q) >= 48 && volatile_load8(sql + q) <= 57) {
                num = num * 10 + (volatile_load8(sql + q) - 48);
                q = q + 1;
            }
            vals[vi] = num;
        } else {
            return 0;
        }
        vi = vi + 1;
    }
    if (vi < 1) {
        return 0;
    }
    let r: int = db_insert(tid, ptr_to_int(&vals[0]));
    if (r == 1) {
        serial_print("1 row inserted\n");
    } else {
        serial_print("insert failed\n");
    }
    return 1;
}

/* SELECT cols FROM name [WHERE col=N] */
fn sql_select(sql: u64) -> int {
    let p1: int = kw_find(sql, "FROM");
    if (p1 < 0) {
        return 0;
    }
    let tname: [32]u8;
    let p: int = p1;
    while (volatile_load8(sql + p) == 32) {
        p = p + 1;
    }
    let tn: int = 0;
    while (volatile_load8(sql + p) != 32 && volatile_load8(sql + p) != 0 && tn < 31) {
        tname[tn] = volatile_load8(sql + p);
        tn = tn + 1;
        p = p + 1;
    }
    tname[tn] = 0;
    let tid: int = db_find_table(int_to_ptr(ptr_to_int(&tname[0])));
    if (tid < 0) {
        serial_print("sql: no such table\n");
        return 1;
    }
    /* WHERE col=N（v1：第 0 列） */
    let wv: int = -1;
    let wp: int = kw_find(sql, "WHERE");
    if (wp >= 0) {
        let eq: int = 0;
        let q: int = wp;
        while (volatile_load8(sql + q) != 61 && volatile_load8(sql + q) != 0) {
            q = q + 1;
        }
        if (volatile_load8(sql + q) == 61) {
            q = q + 1;
            wv = 0;
            while (volatile_load8(sql + q) >= 48 && volatile_load8(sql + q) <= 57) {
                wv = wv * 10 + (volatile_load8(sql + q) - 48);
                q = q + 1;
            }
            eq = 1;
        }
        if (eq == 0) {
            wv = -1;
        }
    }
    /* 打印列名（v1：全列） */
    let i: int = 0;
    while (i < db_tcols[tid]) {
        if (i > 0) {
            serial_putc(32);
        }
        serial_print("c");
        print_int(i);
        i = i + 1;
    }
    serial_putc(10);
    /* 扫描输出 */
    db_scan_init(tid);
    let rec: u64 = db_scan_next();
    let n: int = 0;
    while (rec != 0) {
        let ok: int = 1;
        if (wv >= 0) {
            let c0: int = db_col(rec, tid, 0);
            if (c0 != wv) {
                ok = 0;
            }
        }
        if (ok == 1) {
            let k: int = 0;
            while (k < db_tcols[tid]) {
                if (k > 0) {
                    serial_putc(32);
                }
                let v: u64 = db_col(rec, tid, k);
                if (db_ttypes[tid][k] == 0) {
                    print_int(v);
                } else {
                    let m: int = 0;
                    while (volatile_load8(v + m) != 0) {
                        serial_putc(volatile_load8(v + m));
                        m = m + 1;
                    }
                }
                k = k + 1;
            }
            serial_putc(10);
            n = n + 1;
        }
        rec = db_scan_next();
    }
    serial_print("(N rows)\n");
    return 1;
}

/* 命令分发 */
fn cli_exec(buf: u64) {
    /* 空行 / # 注释行：跳过 */
    if (volatile_load8(buf) == 0 || volatile_load8(buf) == 35) {
        return;
    }
    if (cli_starts(buf, "sql ") == 1) {
        if (kw_find(buf + 4, "CREATE") >= 0) {
            sql_create(buf + 4);
            return;
        }
        if (kw_find(buf + 4, "INSERT") >= 0) {
            sql_insert(buf + 4);
            return;
        }
        if (kw_find(buf + 4, "SELECT") >= 0) {
            sql_select(buf + 4);
            return;
        }
        serial_print("sql: only CREATE/INSERT/SELECT\n");
        return;
    }
    if (cli_starts(buf, "kv ") == 1) {
        let op: [16]u8;
        let k: [32]u8;
        let v: [64]u8;
        cli_arg(buf + 3, 0, ptr_to_int(&op[0]));
        cli_arg(buf + 3, 1, ptr_to_int(&k[0]));
        if (str_eq(ptr_to_int(&op[0]), "get") == 1) {
            let rl: int = kv_get(ptr_to_int(&k[0]), ptr_to_int(&v[0]));
            if (rl < 0) {
                serial_print("kv: not found\n");
            } else {
                serial_print("kv: ");
                let j: int = 0;
                while (j < rl) {
                    serial_putc(volatile_load8(ptr_to_int(&v[0]) + j));
                    j = j + 1;
                }
                serial_putc(10);
            }
        } else if (str_eq(ptr_to_int(&op[0]), "put") == 1) {
            cli_arg(buf + 3, 2, ptr_to_int(&v[0]));
            if (kv_put(ptr_to_int(&k[0]), ptr_to_int(&v[0])) == 1) {
                serial_print("kv put ok\n");
            } else {
                serial_print("kv full\n");
            }
        } else if (str_eq(ptr_to_int(&op[0]), "del") == 1) {
            if (kv_del(ptr_to_int(&k[0])) == 1) {
                serial_print("kv del ok\n");
            } else {
                serial_print("kv: not found\n");
            }
        } else {
            serial_print("kv: op=get|put|del\n");
        }
        return;
    }
    if (cli_starts(buf, "doc ") == 1) {
        let op: [16]u8;
        let n: [32]u8;
        let c: [128]u8;
        cli_arg(buf + 4, 0, ptr_to_int(&op[0]));
        cli_arg(buf + 4, 1, ptr_to_int(&n[0]));
        if (str_eq(ptr_to_int(&op[0]), "get") == 1) {
            let rl: int = doc_get(ptr_to_int(&n[0]), ptr_to_int(&c[0]));
            if (rl < 0) {
                serial_print("doc: not found\n");
            } else {
                serial_print("doc: ");
                let j: int = 0;
                while (j < rl) {
                    serial_putc(volatile_load8(ptr_to_int(&c[0]) + j));
                    j = j + 1;
                }
                serial_putc(10);
            }
        } else if (str_eq(ptr_to_int(&op[0]), "put") == 1) {
            cli_arg(buf + 4, 2, ptr_to_int(&c[0]));
            if (doc_put(ptr_to_int(&n[0]), ptr_to_int(&c[0])) == 1) {
                serial_print("doc put ok\n");
            } else {
                serial_print("doc full\n");
            }
        } else {
            serial_print("doc: op=get|put\n");
        }
        return;
    }
    if (cli_starts(buf, "save ") == 1) {
        let f: [64]u8;
        cli_arg(buf + 5, 0, ptr_to_int(&f[0]));
        db_save(ptr_to_int(&f[0]));
        return;
    }
    if (cli_starts(buf, "load ") == 1) {
        let f: [64]u8;
        cli_arg(buf + 5, 0, ptr_to_int(&f[0]));
        db_load(ptr_to_int(&f[0]));
        return;
    }
    if (cli_starts(buf, "tables") == 1) {
        let i: int = 0;
        while (i < db_ntables) {
            let j: int = 0;
            while (volatile_load8(db_tname[i] + j) != 0) {
                serial_putc(volatile_load8(db_tname[i] + j));
                j = j + 1;
            }
            serial_putc(10);
            i = i + 1;
        }
        return;
    }
    if (cli_starts(buf, "help") == 1) {
        serial_print("pp-db CLI: sql <SQL> | kv get|put|del <k> [v] | doc get|put <name> [json] | save|load <file> | tables | quit\n");
        return;
    }
    serial_print("unknown command (help for usage)\n");
}

/* 读一行（含换行），返回长度；EOF 返回 -1（空行返回 0，由调用方区分） */
fn cli_readline(buf: u64, cap: int) -> int {
    let l: int = 0;
    while (l < cap - 1) {
        let c: int = getchar();
        if (c < 0) {
            if (l == 0) {
                return -1;   /* EOF 且无内容 */
            }
            break;
        }
        if (c == 10) {
            break;   /* \n 结束 */
        }
        volatile_store8(buf + l, c);
        l = l + 1;
    }
    volatile_store8(buf + l, 0);
    return l;
}

static cli_line: [512]u8;   /* 输入行缓冲：static 而非栈，避免跨函数指针问题 */

fn main() -> int {
    serial_print("pp-db CLI (independent database)\n");
    while (1) {
        let l: int = cli_readline(ptr_to_int(&cli_line[0]), 512);
        if (l < 0) {
            break;   /* EOF */
        }
        if (l == 0) {
            continue;   /* 空行 */
        }
        if (cli_starts(ptr_to_int(&cli_line[0]), "quit") == 1 || cli_starts(ptr_to_int(&cli_line[0]), "exit") == 1) {
            break;
        }
        cli_exec(ptr_to_int(&cli_line[0]));
    }
    return 0;
}
