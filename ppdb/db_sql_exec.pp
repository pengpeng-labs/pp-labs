/* db_sql_exec.pp：SQL 执行器——解析结果 → 存储操作（seq_scan/filter/project/CRUD + 表格式输出） */

/* 数字转字符串写缓冲（宿主无关，避免依赖 pp-os 的 itoa_buf），返回长度 */
fn db_itoa(n: int, buf: u64) -> int {
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

/* 找列名在表中的索引；-1 未找到 */
fn db_col_idx(tid: int, name: u64) -> int {
    let i: int = 0;
    while (i < db_tcols[tid]) {
        let j: int = 0;
        let eq: int = 1;
        while (j < 32) {
            let a: int = volatile_load8(db_tcol[tid][i] + j);
            let b: int = volatile_load8(name + j);
            if (a != b) {
                eq = 0;
                break;
            }
            if (a == 0) {
                break;
            }
            j = j + 1;
        }
        if (eq == 1) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn db_cmp_matches(cmp: int, op: DbCmpOp) -> int {
    switch op {
        DbCmpOp.Eq { if (cmp == 0) { return 1; } }
        DbCmpOp.Ne { if (cmp != 0) { return 1; } }
        DbCmpOp.Lt { if (cmp < 0) { return 1; } }
        DbCmpOp.Gt { if (cmp > 0) { return 1; } }
        DbCmpOp.Le { if (cmp <= 0) { return 1; } }
        DbCmpOp.Ge { if (cmp >= 0) { return 1; } }
    }
    return 0;
}

fn db_cmp_text(stored: u64, expected: str) -> int {
    let i: int = 0;
    let n: int = len(expected) as int;
    while (i < n && volatile_load8(stored + i) != 0) {
        let a: int = volatile_load8(stored + i);
        let b: int = expected[i];
        if (a != b) {
            return a - b;
        }
        i = i + 1;
    }
    if (i < n) {
        return 0 - expected[i];
    }
    if (volatile_load8(stored + i) != 0) {
        return volatile_load8(stored + i);
    }
    return 0;
}

/* 条件匹配：rec 行数据，返回 1 匹配 */
fn db_match(rec: u64, tid: int) -> int {
    if (db_stmt_where_col == 0) {
        return 1;
    }
    let col: int = db_col_idx(tid, db_stmt_where_col);
    if (col < 0) {
        return 0;
    }
    let v: u64 = db_col(rec, tid, col);
    switch db_stmt_where_val {
        DbValue.Int(expected) {
            if (db_ttypes[tid][col] != 0) {
                return 0;
            }
            return db_cmp_matches((v as int) - expected, db_stmt_where_op);
        }
        DbValue.Text(expected) {
            if (db_ttypes[tid][col] != 1) {
                return 0;
            }
            return db_cmp_matches(db_cmp_text(v, expected), db_stmt_where_op);
        }
    }
    return 0;
}

/* SELECT * 展开为表目录中保存的真实列名。 */
fn db_expand_star(tid: int) {
    let n: int = db_tcols[tid];
    let i: int = 0;
    while (i < n) {
        db_stmt_cols[i] = db_tcol[tid][i];
        i = i + 1;
    }
    db_stmt_coln = n;
}

struct DbRowCursor {
    indexed: bool,
    seq: DbScan,
    idx: DbIndexScan,
}

static db_last_plan_index: int = -1; /* 测试与诊断：-1=seq scan */

fn db_row_cursor_open(tid: int) -> DbRowCursor {
    let seq: DbScan = db_scan_open(tid);
    let idx_scan: DbIndexScan = db_index_scan_open(0, 0, 0);
    db_last_plan_index = -1;
    if (db_stmt_where_col != 0) {
        let col: int = db_col_idx(tid, db_stmt_where_col);
        if (col >= 0 && db_ttypes[tid][col] == 0) {
            let index_id: int = db_index_find(tid, col);
            if (index_id >= 0) {
                let value: DbValue = db_stmt_where_val;
                switch value {
                    DbValue.Int(key) {
                        let op: int = 0;
                        switch db_stmt_where_op {
                            DbCmpOp.Eq { op = 0; }
                            DbCmpOp.Ne { op = 1; }
                            DbCmpOp.Lt { op = 2; }
                            DbCmpOp.Gt { op = 3; }
                            DbCmpOp.Le { op = 4; }
                            DbCmpOp.Ge { op = 5; }
                        }
                        idx_scan = db_index_scan_open(index_id, key, op);
                        db_last_plan_index = index_id;
                        return DbRowCursor { indexed: true, seq: seq, idx: idx_scan };
                    }
                    DbValue.Text(text) { }
                }
            }
        }
    }
    return DbRowCursor { indexed: false, seq: seq, idx: idx_scan };
}

fn db_row_cursor_next(cursor: *DbRowCursor) -> u64 {
    if (cursor.indexed) { return db_index_scan_next(&cursor.idx); }
    return db_scan_next(&cursor.seq);
}

static db_json_serial_out: [4096]u8;

fn db_result_too_large(out: u64) -> int {
    let msg: str = "sql: result too large\n";
    let i: int = 0;
    while (i < len(msg) as int) {
        volatile_store8(out + i, msg[i]);
        i = i + 1;
    }
    volatile_store8(out + i, 0);
    return i;
}

fn db_json_string(out: u64, o: int, cap: int, value: u64) -> int {
    if (o + 1 >= cap) { return -1; }
    volatile_store8(out + o, 34);
    o = o + 1;
    let i: int = 0;
    while (volatile_load8(value + i) != 0) {
        let c: int = volatile_load8(value + i);
        if (c == 34 || c == 92) {
            if (o + 2 >= cap) { return -1; }
            volatile_store8(out + o, 92);
            o = o + 1;
            volatile_store8(out + o, c);
        } else if (c == 10) {
            if (o + 2 >= cap) { return -1; }
            volatile_store8(out + o, 92);
            o = o + 1;
            volatile_store8(out + o, 110);
        } else if (c == 13) {
            if (o + 2 >= cap) { return -1; }
            volatile_store8(out + o, 92);
            o = o + 1;
            volatile_store8(out + o, 114);
        } else if (c == 9) {
            if (o + 2 >= cap) { return -1; }
            volatile_store8(out + o, 92);
            o = o + 1;
            volatile_store8(out + o, 116);
        } else {
            if (o + 1 >= cap) { return -1; }
            volatile_store8(out + o, c);
        }
        o = o + 1;
        i = i + 1;
    }
    if (o + 1 >= cap) { return -1; }
    volatile_store8(out + o, 34);
    return o + 1;
}

fn db_select_json_to_buf(tid: int, out: u64, cap: int) -> int {
    if (cap < 24) { return 0; }
    if (db_stmt_star == 1) {
        db_expand_star(tid);
    }
    let ci: int = 0;
    while (ci < db_stmt_coln) {
        if (db_col_idx(tid, db_stmt_cols[ci]) < 0) {
            return 0;
        }
        ci = ci + 1;
    }
    let o: int = 0;
    volatile_store8(out + o, 91); /* [ */
    o = o + 1;
    let cursor: DbRowCursor = db_row_cursor_open(tid);
    let rec: u64 = db_row_cursor_next(&cursor);
    let rows: int = 0;
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            if (rows > 0) {
                if (o + 1 >= cap) { return db_result_too_large(out); }
                volatile_store8(out + o, 44);
                o = o + 1;
            }
            if (o + 1 >= cap) { return db_result_too_large(out); }
            volatile_store8(out + o, 123); /* { */
            o = o + 1;
            let k: int = 0;
            while (k < db_stmt_coln) {
                if (k > 0) {
                    if (o + 1 >= cap) { return db_result_too_large(out); }
                    volatile_store8(out + o, 44);
                    o = o + 1;
                }
                o = db_json_string(out, o, cap, db_stmt_cols[k]);
                if (o < 0 || o + 1 >= cap) { return db_result_too_large(out); }
                volatile_store8(out + o, 58);
                o = o + 1;
                let col: int = db_col_idx(tid, db_stmt_cols[k]);
                let value: u64 = db_col(rec, tid, col);
                if (db_ttypes[tid][col] == 0) {
                    if (o + 12 >= cap) { return db_result_too_large(out); }
                    o = o + db_itoa(value as int, out + o);
                } else {
                    o = db_json_string(out, o, cap, value);
                    if (o < 0) { return db_result_too_large(out); }
                }
                k = k + 1;
            }
            if (o + 1 >= cap) { return db_result_too_large(out); }
            volatile_store8(out + o, 125); /* } */
            o = o + 1;
            rows = rows + 1;
            if (db_stmt_limit > 0 && rows >= db_stmt_limit) {
                break;
            }
        }
        rec = db_row_cursor_next(&cursor);
    }
    if (o + 3 > cap) { return db_result_too_large(out); }
    volatile_store8(out + o, 93); /* ] */
    volatile_store8(out + o + 1, 10);
    volatile_store8(out + o + 2, 0);
    return o + 2;
}

/* 执行 SELECT：输出表格式（列名 + 匹配行） */
fn db_exec_select(tid: int) {
    if (db_stmt_to_json == 1) {
        let out: u64 = ptr_to_int(&db_json_serial_out[0]);
        let n: int = db_select_json_to_buf(tid, out, 4096);
        let oi: int = 0;
        while (oi < n) {
            serial_putc(volatile_load8(out + oi));
            oi = oi + 1;
        }
        return;
    }
    if (db_stmt_star == 1) {
        db_expand_star(tid);
    }
    let ci: int = 0;
    while (ci < db_stmt_coln) {
        if (db_col_idx(tid, db_stmt_cols[ci]) < 0) {
            serial_print("sql: no such column\n");
            return;
        }
        ci = ci + 1;
    }
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
    let cursor: DbRowCursor = db_row_cursor_open(tid);
    let rec: u64 = db_row_cursor_next(&cursor);
    let printed: int = 0;
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            let k: int = 0;
            while (k < db_stmt_coln) {
                if (k > 0) {
                    serial_putc(32);
                }
                let col: int = db_col_idx(tid, db_stmt_cols[k]);
                let v: u64 = db_col(rec, tid, col);
                if (db_ttypes[tid][col] == 0) {
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
        rec = db_row_cursor_next(&cursor);
    }
    serial_print("(N rows)\n");
}

/* 执行 SELECT 写缓冲：结果写入 out，返回长度（供 MCP sql 工具返回给 LLM） */
fn db_select_to_buf(tid: int, out: u64, cap: int) -> int {
    if (cap < 24) { return 0; }
    if (db_stmt_to_json == 1) {
        return db_select_json_to_buf(tid, out, cap);
    }
    let o: int = 0;
    if (db_stmt_star == 1) {
        db_expand_star(tid);
    }
    let ci: int = 0;
    while (ci < db_stmt_coln) {
        if (db_col_idx(tid, db_stmt_cols[ci]) < 0) {
            let err: str = "sql: no such column\n";
            let ei: int = 0;
            while (ei < len(err) as int) {
                volatile_store8(out + ei, err[ei]);
                ei = ei + 1;
            }
            volatile_store8(out + ei, 0);
            return ei;
        }
        ci = ci + 1;
    }
    /* 列名 */
    let i: int = 0;
    while (i < db_stmt_coln) {
        if (i > 0) {
            if (o + 1 >= cap) { return db_result_too_large(out); }
            volatile_store8(out + o, 32);
            o = o + 1;
        }
        let j: int = 0;
        while (volatile_load8(db_stmt_cols[i] + j) != 0) {
            if (o + 1 >= cap) { return db_result_too_large(out); }
            volatile_store8(out + o, volatile_load8(db_stmt_cols[i] + j));
            o = o + 1;
            j = j + 1;
        }
        i = i + 1;
    }
    if (o + 1 >= cap) { return db_result_too_large(out); }
    volatile_store8(out + o, 10);
    o = o + 1;
    /* 扫描 + 过滤 + 投影 */
    let cursor: DbRowCursor = db_row_cursor_open(tid);
    let rec: u64 = db_row_cursor_next(&cursor);
    let printed: int = 0;
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            let k: int = 0;
            while (k < db_stmt_coln) {
                if (k > 0) {
                    if (o + 1 >= cap) { return db_result_too_large(out); }
                    volatile_store8(out + o, 32);
                    o = o + 1;
                }
                let col: int = db_col_idx(tid, db_stmt_cols[k]);
                let v: u64 = db_col(rec, tid, col);
                if (db_ttypes[tid][col] == 0) {
                    if (o + 12 >= cap) { return db_result_too_large(out); }
                    o = o + db_itoa(v, out + o);
                } else {
                    let m: int = 0;
                    while (volatile_load8(v + m) != 0) {
                        if (o + 1 >= cap) { return db_result_too_large(out); }
                        volatile_store8(out + o, volatile_load8(v + m));
                        o = o + 1;
                        m = m + 1;
                    }
                }
                k = k + 1;
            }
            if (o + 1 >= cap) { return db_result_too_large(out); }
            volatile_store8(out + o, 10);
            o = o + 1;
            printed = printed + 1;
            if (db_stmt_limit > 0 && printed >= db_stmt_limit) {
                break;
            }
        }
        rec = db_row_cursor_next(&cursor);
    }
    /* 行数标注 */
    let r: str = "(";
    let k2: int = 0;
    while (r[k2] != 0) {
        if (o + 1 >= cap) { return db_result_too_large(out); }
        volatile_store8(out + o, r[k2]);
        o = o + 1;
        k2 = k2 + 1;
    }
    if (o + 12 >= cap) { return db_result_too_large(out); }
    o = o + db_itoa(printed, out + o);
    let r2: str = " rows)\n";
    k2 = 0;
    while (r2[k2] != 0) {
        if (o + 1 >= cap) { return db_result_too_large(out); }
        volatile_store8(out + o, r2[k2]);
        o = o + 1;
        k2 = k2 + 1;
    }
    if (o >= cap) { return db_result_too_large(out); }
    volatile_store8(out + o, 0);
    return o;
}

/* 执行 INSERT */
fn db_exec_insert(tid: int) {
    let vals: [4]u64;
    if (db_stmt_valn != db_stmt_coln || db_stmt_coln != db_tcols[tid]) {
        serial_print("insert: columns/values mismatch\n");
        return;
    }
    let i: int = 0;
    while (i < 4) {
        vals[i] = 0;
        i = i + 1;
    }
    i = 0;
    while (i < db_stmt_valn) {
        let col: int = db_col_idx(tid, db_stmt_cols[i]);
        if (col < 0) {
            serial_print("sql: no such column\n");
            return;
        }
        let stmt_value: DbValue = db_stmt_vals[i];
        switch stmt_value {
            DbValue.Int(value) {
                if (db_ttypes[tid][col] != 0) {
                    serial_print("insert: value type mismatch\n");
                    return;
                }
                vals[col] = value as u64;
            }
            DbValue.Text(value) {
                if (db_ttypes[tid][col] != 1) {
                    serial_print("insert: value type mismatch\n");
                    return;
                }
                vals[col] = ptr_to_int(value);
            }
        }
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
    let col: int = db_col_idx(tid, db_stmt_cols[0]);
    if (col < 0) {
        serial_print("sql: no such column\n");
        return;
    }
    let scan: DbScan = db_scan_open(tid);
    let rec: u64 = db_scan_next(&scan);
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            let dst: u64 = db_col_ptr(rec, tid, col);
            let stmt_value: DbValue = db_stmt_vals[0];
            switch stmt_value {
                DbValue.Int(value) {
                    if (db_ttypes[tid][col] != 0) {
                        serial_print("update: value type mismatch\n");
                        return;
                    }
                    volatile_store32(dst, value);
                }
                DbValue.Text(value) {
                    if (db_ttypes[tid][col] != 1) {
                        serial_print("update: value type mismatch\n");
                        return;
                    }
                    let src: u64 = ptr_to_int(value);
                    let value_len: int = len(value) as int;
                    let k: int = 0;
                    while (k < 32) {
                        volatile_store8(dst + k, 0);
                        k = k + 1;
                    }
                    k = 0;
                    while (k < 31 && k < value_len) {
                        volatile_store8(dst + k, volatile_load8(src + k));
                        k = k + 1;
                    }
                }
            }
            n = n + 1;
        }
        rec = db_scan_next(&scan);
    }
    db_index_rebuild_table(tid);
    serial_print("updated ");
    print_int(n);
    serial_print(" rows\n");
}

/* 执行 DELETE */
fn db_exec_delete(tid: int) {
    let n: int = 0;
    let scan: DbScan = db_scan_open(tid);
    let rec: u64 = db_scan_next(&scan);
    while (rec != 0) {
        if (db_match(rec, tid) == 1) {
            db_scan_delete(&scan);
            n = n + 1;
        }
        rec = db_scan_next(&scan);
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
    switch db_stmt_kind {
        DbStmtKind.Begin {
            if (db_tx_begin()) { serial_print("transaction begun\n"); return 0; }
            serial_print("transaction already active\n");
            return 1;
        }
        DbStmtKind.Commit {
            if (db_tx_commit()) { serial_print("transaction committed\n"); return 0; }
            serial_print("no active transaction\n");
            return 1;
        }
        DbStmtKind.Rollback {
            if (db_tx_rollback()) { serial_print("transaction rolled back\n"); return 0; }
            serial_print("no active transaction\n");
            return 1;
        }
        DbStmtKind.Create {
            let r: int = db_create_table(int_to_ptr(db_stmt_table), db_stmt_coln,
                db_stmt_types[0], db_stmt_types[1], db_stmt_types[2], db_stmt_types[3]);
            if (r >= 0) {
                db_set_col_names(r, db_stmt_cols[0], db_stmt_cols[1], db_stmt_cols[2], db_stmt_cols[3]);
                serial_print("table created\n");
                return 0;
            }
            serial_print("create failed\n");
            return 1;
        }
        DbStmtKind.CreateIndex {
            let table_id: int = db_find_table(int_to_ptr(db_stmt_table));
            if (table_id < 0) {
                serial_print("sql: no such table\n");
                return 1;
            }
            let col: int = db_col_idx(table_id, db_stmt_cols[0]);
            if (col < 0) {
                serial_print("sql: no such column\n");
                return 1;
            }
            if (db_index_create(db_stmt_index, table_id, col) < 0) {
                serial_print("create index failed\n");
                return 1;
            }
            serial_print("index created\n");
            return 0;
        }
        DbStmtKind.Drop {
            let tid5: int = db_find_table(int_to_ptr(db_stmt_table));
            if (tid5 >= 0) {
                db_drop_table(tid5);
                serial_print("table dropped\n");
            } else {
                serial_print("sql: no such table\n");
            }
            return 0;
        }
        DbStmtKind.Insert { db_exec_insert(tid); return 0; }
        DbStmtKind.Select { db_exec_select(tid); return 0; }
        DbStmtKind.Update { db_exec_update(tid); return 0; }
        DbStmtKind.Delete { db_exec_delete(tid); return 0; }
    }
    return 1;
}
