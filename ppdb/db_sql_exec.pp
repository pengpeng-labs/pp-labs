/* db_sql_exec.pp：SQL 执行器——解析结果 → 存储操作（seq_scan/filter/project/CRUD + 表格式输出） */

/* 数字转字符串写缓冲（宿主无关，避免依赖 pp-os 的 itoa_buf），返回长度 */
fn db_itoa(n: int, buf: int) -> int {
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

/* 找列名在表中的索引；-1 未找到 */
fn db_col_idx(tid: int, name: int) -> int {
    let i: int = 0;
    while (i < db_tcols[tid]) {
        /* 比较 db_tname？——列名没存表目录！——v1：列名与 db_stmt_cols 中的一致
           简化：按位置匹配（调用方保证列顺序）——列索引 = 传入的列序号
           这里实现"按名查找"需要表目录存列名——v1 用位置 */
        i = i + 1;
    }
    return 0;
}

/* 条件匹配：rec 行数据，返回 1 匹配 */
fn db_match(rec: u64, tid: int) -> int {
    if (db_stmt_where_col == 0) {
        return 1;
    }
    /* where 列名 → 索引（按列名匹配：比较 db_stmt_where_col 与 db_stmt_cols？——
       where 用列名，需在表列中找——v1 简化：where 列索引 = 0（首列）——
       更通用：执行器层传入列映射——这里按"列名在 SELECT 列表中的位置"？——
       简化：where 列固定为表的第一列（v1 限制，文档注明） */
    let col: int = 0;
    let v: u64 = db_col(rec, tid, col);
    if (db_stmt_where_isstr == 1) {
        /* 字符串比较（v1：比较首字符简化——实际应完整比较） */
        let sv: int = db_stmt_where_val;
        let k: int = 0;
        let eq: int = 1;
        while (1) {
            let a: int = volatile_load8(v + k);
            let b: int = volatile_load8(sv + k);
            if (a != b) {
                eq = 0;
                break;
            }
            if (a == 0) {
                break;
            }
            k = k + 1;
        }
        if (db_stmt_where_op == 0) {
            return eq;
        }
        return 1 - eq;
    }
    /* 数字比较 */
    let sv: int = db_stmt_where_val;
    if (db_stmt_where_op == 0) {
        if (v == sv) { return 1; }
    } else if (db_stmt_where_op == 1) {
        if (v != sv) { return 1; }
    } else if (db_stmt_where_op == 2) {
        if (v < sv) { return 1; }
    } else if (db_stmt_where_op == 3) {
        if (v > sv) { return 1; }
    } else if (db_stmt_where_op == 4) {
        if (v <= sv) { return 1; }
    } else if (db_stmt_where_op == 5) {
        if (v >= sv) { return 1; }
    }
    return 0;
}

/* 执行 SELECT：输出表格式（列名 + 匹配行） */
fn db_exec_select(tid: int) {
    /* 打印列名 */
    let i: int = 0;
    while (i < db_stmt_coln) {
        if (i > 0) {
            serial_putc(32);
        }
        let j: int = 0;
        while (volatile_load8(db_stmt_cols[i] + j) != 0) {
            serial_putc(volatile_load8(db_stmt_cols[i] + j));
            j = j + 1;
        }
        i = i + 1;
    }
    serial_putc(10);
    /* 扫描 + 过滤 + 投影 */
    db_scan_init(tid);
    let rec: u64 = db_scan_next();
    let printed: int = 0;
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            let k: int = 0;
            while (k < db_stmt_coln) {
                if (k > 0) {
                    serial_putc(32);
                }
                /* 列值：按列名映射到表列——v1：SELECT 列顺序 = 表列顺序 */
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
            printed = printed + 1;
            if (db_stmt_limit > 0 && printed >= db_stmt_limit) {
                break;
            }
        }
        rec = db_scan_next();
    }
    serial_print("(N rows)\n");
}

/* 执行 SELECT 写缓冲：结果写入 out，返回长度（供 MCP sql 工具返回给 LLM） */
fn db_select_to_buf(tid: int, out: int) -> int {
    let o: int = 0;
    /* 列名 */
    let i: int = 0;
    while (i < db_stmt_coln) {
        if (i > 0) {
            volatile_store8(out + o, 32);
            o = o + 1;
        }
        let j: int = 0;
        while (volatile_load8(db_stmt_cols[i] + j) != 0) {
            volatile_store8(out + o, volatile_load8(db_stmt_cols[i] + j));
            o = o + 1;
            j = j + 1;
        }
        i = i + 1;
    }
    volatile_store8(out + o, 10);
    o = o + 1;
    /* 扫描 + 过滤 + 投影 */
    db_scan_init(tid);
    let rec: u64 = db_scan_next();
    let printed: int = 0;
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            let k: int = 0;
            while (k < db_stmt_coln) {
                if (k > 0) {
                    volatile_store8(out + o, 32);
                    o = o + 1;
                }
                let v: u64 = db_col(rec, tid, k);
                if (db_ttypes[tid][k] == 0) {
                    o = o + db_itoa(v, out + o);
                } else {
                    let m: int = 0;
                    while (volatile_load8(v + m) != 0) {
                        volatile_store8(out + o, volatile_load8(v + m));
                        o = o + 1;
                        m = m + 1;
                    }
                }
                k = k + 1;
            }
            volatile_store8(out + o, 10);
            o = o + 1;
            printed = printed + 1;
            if (db_stmt_limit > 0 && printed >= db_stmt_limit) {
                break;
            }
        }
        rec = db_scan_next();
    }
    /* 行数标注 */
    let r: str = "(";
    let k2: int = 0;
    while (r[k2] != 0) {
        volatile_store8(out + o, r[k2]);
        o = o + 1;
        k2 = k2 + 1;
    }
    o = o + db_itoa(printed, out + o);
    let r2: str = " rows)\n";
    k2 = 0;
    while (r2[k2] != 0) {
        volatile_store8(out + o, r2[k2]);
        o = o + 1;
        k2 = k2 + 1;
    }
    volatile_store8(out + o, 0);
    return o;
}

/* 执行 INSERT */
fn db_exec_insert(tid: int) {
    let vals: [u64; 4];
    let i: int = 0;
    while (i < db_stmt_valn && i < 4) {
        vals[i] = db_stmt_vals[i];
        i = i + 1;
    }
    let r: int = db_insert(tid, ptr_to_int(&vals[0]));
    if (r == 1) {
        serial_print("1 row inserted\n");
    } else {
        serial_print("insert failed\n");
    }
}

/* 执行 UPDATE */
fn db_exec_update(tid: int) {
    let n: int = 0;
    db_scan_init(tid);
    let rec: u64 = db_scan_next();
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            /* 更新第 0 列（v1 简化：SET 列 = 表第 0 列） */
            let v: int = db_stmt_vals[0];
            if (db_ttypes[tid][0] == 0) {
                volatile_store32(rec, v);
            } else {
                let k: int = 0;
                while (k < 32) {
                    volatile_store8(rec + k, volatile_load8(v + k));
                    if (volatile_load8(v + k) == 0) {
                        break;
                    }
                    k = k + 1;
                }
            }
            n = n + 1;
        }
        rec = db_scan_next();
    }
    serial_print("updated ");
    print_int(n);
    serial_print(" rows\n");
}

/* 执行 DELETE */
fn db_exec_delete(tid: int) {
    let n: int = 0;
    db_scan_init(tid);
    let rec: u64 = db_scan_next();
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            db_scan_delete();
            n = n + 1;
        }
        rec = db_scan_next();
    }
    serial_print("deleted ");
    print_int(n);
    serial_print(" rows\n");
}

/* 表目录：列出全部表（名字 + 列类型 schema） */
fn db_list() {
    let i: int = 0;
    while (i < db_ntables) {
        let j: int = 0;
        while (volatile_load8(db_tname[i] + j) != 0) {
            serial_putc(volatile_load8(db_tname[i] + j));
            j = j + 1;
        }
        serial_print(" (");
        let l: int = db_schema(i, 0x400C00);
        let k: int = 0;
        while (k < l) {
            serial_putc(volatile_load8(0x400C00 + k));
            k = k + 1;
        }
        serial_print(")\n");
        i = i + 1;
    }
    serial_print("(N tables)\n");
}

/* 全部表 schema 写缓冲（供 db ask 喂 LLM）："t (int,str) t2 (int)"，返回长度
   注意：JSON 字符串内不能有裸换行——用空格分隔（DeepSeek 400 于控制字符） */
fn db_schema_to_buf(out: int) -> int {
    let o: int = 0;
    let i: int = 0;
    while (i < db_ntables) {
        if (i > 0) {
            volatile_store8(out + o, 32);
            o = o + 1;
        }
        let j: int = 0;
        while (volatile_load8(db_tname[i] + j) != 0) {
            volatile_store8(out + o, volatile_load8(db_tname[i] + j));
            o = o + 1;
            j = j + 1;
        }
        let h: str = " (";
        let k0: int = 0;
        while (h[k0] != 0) {
            volatile_store8(out + o, h[k0]);
            o = o + 1;
            k0 = k0 + 1;
        }
        let l: int = db_schema(i, out + o);
        o = o + l;
        let t: str = ")";
        k0 = 0;
        while (t[k0] != 0) {
            volatile_store8(out + o, t[k0]);
            o = o + 1;
            k0 = k0 + 1;
        }
        i = i + 1;
    }
    volatile_store8(out + o, 0);
    return o;
}

/* 执行当前解析的语句；tid 已解析的表；返回 0 成功 */
fn db_exec(tid: int) -> int {
    if (db_stmt_type == 0) {
        /* CREATE（tid 为 -1，需创建） */
        let r: int = db_create_table(int_to_ptr(db_stmt_table), db_stmt_coln,
            db_stmt_types[0], db_stmt_types[1], db_stmt_types[2], db_stmt_types[3]);
        if (r >= 0) {
            serial_print("table created\n");
            return 0;
        }
        serial_print("create failed\n");
        return 1;
    }
    if (db_stmt_type == 5) {
        /* DROP */
        let tid5: int = db_find_table(int_to_ptr(db_stmt_table));
        if (tid5 >= 0) {
            db_drop_table(tid5);
            serial_print("table dropped\n");
        } else {
            serial_print("sql: no such table\n");
        }
        return 0;
    }
    if (db_stmt_type == 1) {
        db_exec_insert(tid);
        return 0;
    }
    if (db_stmt_type == 2) {
        db_exec_select(tid);
        return 0;
    }
    if (db_stmt_type == 3) {
        db_exec_update(tid);
        return 0;
    }
    if (db_stmt_type == 4) {
        db_exec_delete(tid);
        return 0;
    }
    return 1;
}
