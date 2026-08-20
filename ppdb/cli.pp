/* cli.pp：pp-db 宿主机 CLI（独立分发入口）——REPL + 管道批处理
   用法：
     pp obj cli.pp && cc cli.o -o ppdb
     ./ppdb                 交互式（sql> / kv> / doc>）
     echo "sql ..." | ./ppdb  批处理（逐行执行）
   命令：sql <SQL>（共享 CREATE/DROP/INSERT/SELECT/UPDATE/DELETE）、kv get|put|del、doc get|put、
         save <file>、load <file>、tables、quit
   说明：native CLI、pp-os 与 MCP 共用 db_sql_parse + db_sql_exec。 */

import "db_core.pp";
import "db_kv.pp";
import "db_doc.pp";
import "db_tx.pp";
import "db_persist.pp";
import "db_sql_parse.pp";
import "db_sql_exec.pp";
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
    let n: int = len(s) as int;
    while (i < n) {
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
    let n: int = len(s) as int;
    while (i < n) {
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
    let n: int = len(s) as int;
    while (i < n) {
        let a: int = volatile_load8(buf + i);
        let b: int = s[i];
        if (a != b) {
            return 0;
        }
        i = i + 1;
    }
    if (volatile_load8(buf + n) == 0) {
        return 1;
    }
    return 0;
}

/* 提取第 k 个空白分隔参数到 out（拷贝），返回 1 有 */
fn cli_arg(buf: u64, k: int, out: u64, cap: int) -> int {
    let pos: int = 0;
    let cur: int = 0;
    while (true) {
        while (volatile_load8(buf + pos) == 32 || volatile_load8(buf + pos) == 9
               || volatile_load8(buf + pos) == 10 || volatile_load8(buf + pos) == 13) {
            pos = pos + 1;
        }
        if (volatile_load8(buf + pos) == 0) {
            return 0;
        }
        if (cur == k) {
            let o: int = 0;
            while (o < cap - 1 && volatile_load8(buf + pos) != 0 && volatile_load8(buf + pos) != 32
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

/* 命令分发 */
fn cli_exec(buf: u64) {
    /* 空行 / # 注释行：跳过 */
    if (volatile_load8(buf) == 0 || volatile_load8(buf) == 35) {
        return;
    }
    if (cli_starts(buf, "sql ") == 1) {
        if (db_parse_sql(buf + 4) < 0) {
            serial_print("sql: syntax error\n");
            return;
        }
        if (db_stmt_is_create() || db_stmt_is_tx()) {
            db_exec(-1);
            return;
        }
        let tid: int = db_find_table(int_to_ptr(db_stmt_table));
        if (tid < 0) {
            serial_print("sql: no such table\n");
            return;
        }
        db_exec(tid);
        return;
    }
    if (cli_starts(buf, "kv ") == 1) {
        let op: [16]u8;
        let k: [32]u8;
        let v: [64]u8;
        cli_arg(buf + 3, 0, ptr_to_int(&op[0]), 16);
        cli_arg(buf + 3, 1, ptr_to_int(&k[0]), 32);
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
            cli_arg(buf + 3, 2, ptr_to_int(&v[0]), 64);
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
        cli_arg(buf + 4, 0, ptr_to_int(&op[0]), 16);
        cli_arg(buf + 4, 1, ptr_to_int(&n[0]), 32);
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
            cli_arg(buf + 4, 2, ptr_to_int(&c[0]), 128);
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
        cli_arg(buf + 5, 0, ptr_to_int(&f[0]), 64);
        db_save(ptr_to_int(&f[0]));
        return;
    }
    if (cli_starts(buf, "load ") == 1) {
        let f: [64]u8;
        cli_arg(buf + 5, 0, ptr_to_int(&f[0]), 64);
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
    if (cli_starts(buf, "indexes") == 1) {
        let i: int = 0;
        while (i < db_nindexes) {
            let j: int = 0;
            while (db_idx_name[i][j] != 0) {
                serial_putc(db_idx_name[i][j]);
                j = j + 1;
            }
            serial_putc(32);
            j = 0;
            while (volatile_load8(db_tname[db_idx_tid[i]] + j) != 0) {
                serial_putc(volatile_load8(db_tname[db_idx_tid[i]] + j));
                j = j + 1;
            }
            serial_putc(46);
            j = 0;
            while (volatile_load8(db_tcol[db_idx_tid[i]][db_idx_col[i]] + j) != 0) {
                serial_putc(volatile_load8(db_tcol[db_idx_tid[i]][db_idx_col[i]] + j));
                j = j + 1;
            }
            serial_putc(10);
            i = i + 1;
        }
        return;
    }
    if (cli_starts(buf, "help") == 1) {
        serial_print("pp-db CLI: sql <SQL> | kv get|put|del <k> [v] | doc get|put <name> [json] | save|load <file> | tables|indexes | quit\n");
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
    while (true) {
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
