/* db_sql_parse.pp：SQL 子集解析器（token 化 + 语句结构提取）
   支持：CREATE TABLE / DROP TABLE / INSERT INTO / SELECT(WHERE/LIMIT) / UPDATE / DELETE */

enum DbValue {
    Int(int),
    Text(str),
}

enum DbCmpOp {
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
}

enum DbStmtKind {
    Begin,
    Commit,
    Rollback,
    Create,
    CreateIndex,
    Insert,
    Select,
    Update,
    Delete,
    Drop,
}

/* 解析结果（全局状态，执行器读取） */
static db_stmt_kind: DbStmtKind;
static db_stmt_table: u64 = 0;        /* 表名指针 */
static db_stmt_index: u64 = 0;        /* 索引名指针 */
static db_stmt_cols: [4]u64;          /* 列名指针 */
static db_stmt_coln: int = 0;
static db_stmt_types: [4]int;       /* create 的列类型（0=int 1=str） */
static db_stmt_vals: [4]DbValue;
static db_stmt_valn: int = 0;
static db_stmt_where_col: u64 = 0;    /* where 列名指针（0=无） */
static db_stmt_where_op: DbCmpOp;
static db_stmt_where_val: DbValue;
static db_stmt_limit: int = 0;        /* 0=不限 */
static db_stmt_star: int = 0;         /* SELECT * 通配符（1=展开所有列） */
static db_stmt_to_json: int = 0;      /* SELECT ... TO JSON */

/* 解析器拥有结果缓冲；不再依赖 pp-os 固定地址，native/pp-os 可共享。 */
static db_parse_kw_buf: [32]u8;
static db_parse_table_buf: [32]u8;
static db_parse_index_buf: [32]u8;
static db_parse_tmp_buf: [32]u8;
static db_parse_where_col_buf: [32]u8;
static db_parse_cols_buf: [4][32]u8;
static db_parse_vals_buf: [4][32]u8;
static db_parse_where_val_buf: [32]u8;
static db_parse_num: int = 0;

fn db_parse_text(buf: u64) -> str {
    let n: int = 0;
    while (n < 31 && volatile_load8(buf + n) != 0) {
        n = n + 1;
    }
    return str_from_ptr(buf as *u8, n);
}

fn db_stmt_is_create() -> bool {
    switch db_stmt_kind {
        DbStmtKind.Create { return true; }
        DbStmtKind.CreateIndex { return true; }
        _ { return false; }
    }
    return false;
}

fn db_stmt_is_create_index() -> bool {
    switch db_stmt_kind {
        DbStmtKind.CreateIndex { return true; }
        _ { return false; }
    }
    return false;
}

fn db_stmt_is_drop() -> bool {
    switch db_stmt_kind {
        DbStmtKind.Drop { return true; }
        _ { return false; }
    }
    return false;
}

fn db_stmt_is_tx() -> bool {
    switch db_stmt_kind {
        DbStmtKind.Begin { return true; }
        DbStmtKind.Commit { return true; }
        DbStmtKind.Rollback { return true; }
        _ { return false; }
    }
    return false;
}

/* ---- token 化辅助 ---- */

/* 跳过空白，返回下一 token 位置 */
fn db_skip_ws(sql: u64, pos: int) -> int {
    while (volatile_load8(sql + pos) == 32 || volatile_load8(sql + pos) == 9) {
        pos = pos + 1;
    }
    return pos;
}

/* 读标识符到 buf（≤31），返回下一位置；无标识符返回 -1 */
fn db_read_ident(sql: u64, pos: int, buf: u64) -> int {
    let p: int = db_skip_ws(sql, pos);
    let c: int = volatile_load8(sql + p);
    if (!((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95)) {
        return -1;
    }
    let o: int = 0;
    while ((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95) {
        if (o < 31) {
            volatile_store8(buf + o, c);
        }
        o = o + 1;
        p = p + 1;
        c = volatile_load8(sql + p);
    }
    if (o > 31) {
        return -1;
    }
    volatile_store8(buf + o, 0);
    return p;
}

/* 读数字（int），返回下一位置；无数字返回 -1 */
fn db_read_num(sql: u64, pos: int, out: u64) -> int {
    let p: int = db_skip_ws(sql, pos);
    let c: int = volatile_load8(sql + p);
    if (c < 48 || c > 57) {
        return -1;
    }
    let v: int = 0;
    while (c >= 48 && c <= 57) {
        v = v * 10 + (c - 48);
        p = p + 1;
        c = volatile_load8(sql + p);
    }
    volatile_store32(out, v);
    return p;
}

/* 读字符串字面量（'...'），拷入调用方提供的 32B 槽。 */
fn db_read_str(sql: u64, pos: int, buf: u64) -> int {
    let p: int = db_skip_ws(sql, pos);
    if (volatile_load8(sql + p) != 39) {   /* ' */
        return -1;
    }
    p = p + 1;
    let o: int = 0;
    while (volatile_load8(sql + p) != 39 && volatile_load8(sql + p) != 0) {
        if (o >= 31) {
            return -1;
        }
        volatile_store8(buf + o, volatile_load8(sql + p));
        o = o + 1;
        p = p + 1;
    }
    if (volatile_load8(sql + p) != 39) {
        return -1;
    }
    volatile_store8(buf + o, 0);
    return p + 1;
}

/* 跳过符号（返回下一位置）；不匹配返回 -1 */
fn db_skip_sym(sql: u64, pos: int, sym: str) -> int {
    let p: int = db_skip_ws(sql, pos);
    let i: int = 0;
    let n: int = len(sym) as int;
    while (i < n) {
        if (volatile_load8(sql + p + i) != sym[i]) {
            return -1;
        }
        i = i + 1;
    }
    return p + i;
}

/* 比较 buf 处标识符与字面量（大小写不敏感） */
fn db_kw(buf: u64, kw: str) -> int {
    let i: int = 0;
    let n: int = len(kw) as int;
    while (i < n) {
        let c: int = volatile_load8(buf + i);
        if (c >= 97 && c <= 122) {
            c = c - 32;
        }
        let k: int = kw[i];
        if (k >= 97 && k <= 122) {
            k = k - 32;
        }
        if (c != k) {
            return 0;
        }
        i = i + 1;
    }
    if (volatile_load8(buf + n) != 0) {
        return 0;
    }
    return 1;
}

/* ---- 主解析 ---- */

/* 解析 WHERE 条件：返回下一位置；cond_col/op/val/isstr 写入全局 */
fn db_parse_where(sql: u64, pos: int) -> int {
    let colbuf: u64 = ptr_to_int(&db_parse_where_col_buf[0]);
    let p: int = db_read_ident(sql, pos, colbuf);
    if (p < 0) {
        return -1;
    }
    db_stmt_where_col = colbuf;
    /* 操作符 */
    let p2: int = db_skip_sym(sql, p, "!=");
    if (p2 >= 0) {
        db_stmt_where_op = DbCmpOp.Ne();
    } else {
        p2 = db_skip_sym(sql, p, "<=");
        if (p2 >= 0) {
            db_stmt_where_op = DbCmpOp.Le();
        } else {
            p2 = db_skip_sym(sql, p, ">=");
            if (p2 >= 0) {
                db_stmt_where_op = DbCmpOp.Ge();
            } else {
                p2 = db_skip_sym(sql, p, "<");
                if (p2 >= 0) {
                    db_stmt_where_op = DbCmpOp.Lt();
                } else {
                    p2 = db_skip_sym(sql, p, ">");
                    if (p2 >= 0) {
                        db_stmt_where_op = DbCmpOp.Gt();
                    } else {
                        p2 = db_skip_sym(sql, p, "=");
                        if (p2 >= 0) {
                            db_stmt_where_op = DbCmpOp.Eq();
                        } else {
                            return -1;
                        }
                    }
                }
            }
        }
    }
    /* 值：数字或字符串 */
    let n: int = 0;
    let p3: int = db_read_num(sql, p2, ptr_to_int(&db_parse_num));
    if (p3 >= 0) {
        db_stmt_where_val = DbValue.Int(db_parse_num);
    } else {
        let where_buf: u64 = ptr_to_int(&db_parse_where_val_buf[0]);
        let p4: int = db_read_str(sql, p2, where_buf);
        if (p4 >= 0) {
            db_stmt_where_val = DbValue.Text(db_parse_text(where_buf));
            p3 = p4;
        } else {
            return -1;
        }
    }
    return p3;
}

/* 解析 SQL 语句（sql 指向文本），填充全局；返回语句类型，-1 错误 */
fn db_parse_sql(sql: u64) -> int {
    db_stmt_coln = 0;
    db_stmt_valn = 0;
    db_stmt_where_col = 0;
    db_stmt_limit = 0;
    db_stmt_star = 0;
    db_stmt_to_json = 0;
    let kwbuf: u64 = ptr_to_int(&db_parse_kw_buf[0]);
    let p: int = db_read_ident(sql, 0, kwbuf);
    if (p < 0) {
        return -1;
    }
    if (db_kw(kwbuf, "BEGIN") == 1) {
        db_stmt_kind = DbStmtKind.Begin();
        return 0;
    }
    if (db_kw(kwbuf, "COMMIT") == 1) {
        db_stmt_kind = DbStmtKind.Commit();
        return 0;
    }
    if (db_kw(kwbuf, "ROLLBACK") == 1) {
        db_stmt_kind = DbStmtKind.Rollback();
        return 0;
    }
    if (db_kw(kwbuf, "CREATE") == 1) {
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0) {
            return -1;
        }
        if (db_kw(kwbuf, "INDEX") == 1) {
            let iname: u64 = ptr_to_int(&db_parse_index_buf[0]);
            let pi: int = db_read_ident(sql, pb, iname);
            if (pi < 0) { return -1; }
            let pon: int = db_read_ident(sql, pi, kwbuf);
            if (pon < 0 || db_kw(kwbuf, "ON") == 0) { return -1; }
            let tname_i: u64 = ptr_to_int(&db_parse_table_buf[0]);
            let pt_i: int = db_read_ident(sql, pon, tname_i);
            if (pt_i < 0) { return -1; }
            let pl: int = db_skip_sym(sql, pt_i, "(");
            if (pl < 0) { return -1; }
            let cname_i: u64 = ptr_to_int(&db_parse_cols_buf[0][0]);
            let pc_i: int = db_read_ident(sql, pl, cname_i);
            if (pc_i < 0 || db_skip_sym(sql, pc_i, ")") < 0) { return -1; }
            db_stmt_index = iname;
            db_stmt_table = tname_i;
            db_stmt_cols[0] = cname_i;
            db_stmt_coln = 1;
            db_stmt_kind = DbStmtKind.CreateIndex();
            return 0;
        }
        /* CREATE TABLE name (col TYPE, ...) */
        if (db_kw(kwbuf, "TABLE") == 0) { return -1; }
        let tname: u64 = ptr_to_int(&db_parse_table_buf[0]);
        let pt: int = db_read_ident(sql, pb, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        let ps: int = db_skip_sym(sql, pt, "(");
        if (ps < 0) {
            return -1;
        }
        while (true) {
            if (db_stmt_coln >= 4) {
                return -1;
            }
            let cname: u64 = ptr_to_int(&db_parse_cols_buf[db_stmt_coln][0]);
            let pc: int = db_read_ident(sql, ps, cname);
            if (pc < 0) {
                return -1;
            }
            db_stmt_cols[db_stmt_coln] = cname;
            let tname2: u64 = ptr_to_int(&db_parse_tmp_buf[0]);
            let pt2: int = db_read_ident(sql, pc, tname2);
            if (pt2 < 0) {
                return -1;
            }
            if (db_kw(tname2, "INT") == 1) {
                db_stmt_types[db_stmt_coln] = 0;
            } else {
                db_stmt_types[db_stmt_coln] = 1;   /* STR */
                /* 跳过 STR(n) 的 (n) */
                let ps2: int = db_skip_sym(sql, pt2, "(");
                if (ps2 >= 0) {
                    let pn: int = db_read_num(sql, ps2, ptr_to_int(&db_parse_num));
                    if (pn >= 0) {
                        let pc2: int = db_skip_sym(sql, pn, ")");
                        if (pc2 >= 0) {
                            pt2 = pc2;
                        }
                    }
                }
            }
            db_stmt_coln = db_stmt_coln + 1;
            ps = pt2;
            let pc3: int = db_skip_sym(sql, ps, ",");
            if (pc3 >= 0) {
                ps = pc3;
            } else {
                break;
            }
        }
        let pe: int = db_skip_sym(sql, ps, ")");
        if (pe < 0) {
            return -1;
        }
        db_stmt_kind = DbStmtKind.Create();
        return 0;
    }
    if (db_kw(kwbuf, "DROP") == 1) {
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0 || db_kw(kwbuf, "TABLE") == 0) {
            return -1;
        }
        let tname: u64 = ptr_to_int(&db_parse_table_buf[0]);
        let pt: int = db_read_ident(sql, pb, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        db_stmt_kind = DbStmtKind.Drop();
        return 0;
    }
    if (db_kw(kwbuf, "INSERT") == 1) {
        /* INSERT INTO name (col, ...) VALUES (v, ...) */
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0 || db_kw(kwbuf, "INTO") == 0) {
            return -1;
        }
        let tname: u64 = ptr_to_int(&db_parse_table_buf[0]);
        let pt: int = db_read_ident(sql, pb, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        let ps: int = db_skip_sym(sql, pt, "(");
        if (ps < 0) {
            return -1;
        }
        while (true) {
            if (db_stmt_coln >= 4) {
                return -1;
            }
            let cname: u64 = ptr_to_int(&db_parse_cols_buf[db_stmt_coln][0]);
            let pc: int = db_read_ident(sql, ps, cname);
            if (pc < 0) {
                return -1;
            }
            db_stmt_cols[db_stmt_coln] = cname;
            db_stmt_coln = db_stmt_coln + 1;
            ps = pc;
            let pc2: int = db_skip_sym(sql, ps, ",");
            if (pc2 >= 0) {
                ps = pc2;
            } else {
                break;
            }
        }
        let pe: int = db_skip_sym(sql, ps, ")");
        if (pe < 0) {
            return -1;
        }
        let pv: int = db_read_ident(sql, pe, kwbuf);
        if (pv < 0 || db_kw(kwbuf, "VALUES") == 0) {
            return -1;
        }
        let ps2: int = db_skip_sym(sql, pv, "(");
        if (ps2 < 0) {
            return -1;
        }
        while (true) {
            let n: int = 0;
            if (db_stmt_valn >= 4) {
                return -1;
            }
            let pn: int = db_read_num(sql, ps2, ptr_to_int(&db_parse_num));
            if (pn >= 0) {
                db_stmt_vals[db_stmt_valn] = DbValue.Int(db_parse_num);
            } else {
                let value_buf: u64 = ptr_to_int(&db_parse_vals_buf[db_stmt_valn][0]);
                let pstr: int = db_read_str(sql, ps2, value_buf);
                if (pstr >= 0) {
                    db_stmt_vals[db_stmt_valn] = DbValue.Text(db_parse_text(value_buf));
                    pn = pstr;
                } else {
                    return -1;
                }
            }
            db_stmt_valn = db_stmt_valn + 1;
            ps2 = pn;
            let pc3: int = db_skip_sym(sql, ps2, ",");
            if (pc3 >= 0) {
                ps2 = pc3;
            } else {
                break;
            }
        }
        let pe2: int = db_skip_sym(sql, ps2, ")");
        if (pe2 < 0) {
            return -1;
        }
        db_stmt_kind = DbStmtKind.Insert();
        return 0;
    }
    if (db_kw(kwbuf, "SELECT") == 1) {
        /* SELECT col, ... FROM name [WHERE ...] [LIMIT n]；或 SELECT * FROM name */
        let ps: int = p;
        let pstar: int = db_skip_sym(sql, ps, "*");
        if (pstar >= 0) {
            db_stmt_star = 1;
            ps = pstar;
        } else {
            while (true) {
                if (db_stmt_coln >= 4) {
                    return -1;
                }
                let cname: u64 = ptr_to_int(&db_parse_cols_buf[db_stmt_coln][0]);
                let pc: int = db_read_ident(sql, ps, cname);
                if (pc < 0) {
                    return -1;
                }
                db_stmt_cols[db_stmt_coln] = cname;
                db_stmt_coln = db_stmt_coln + 1;
                ps = pc;
                let pc2: int = db_skip_sym(sql, ps, ",");
                if (pc2 >= 0) {
                    ps = pc2;
                } else {
                    break;
                }
            }
        }
        let pf: int = db_read_ident(sql, ps, kwbuf);
        if (pf < 0 || db_kw(kwbuf, "FROM") == 0) {
            return -1;
        }
        let tname: u64 = ptr_to_int(&db_parse_table_buf[0]);
        let pt: int = db_read_ident(sql, pf, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        let pp: int = pt;
        /* WHERE */
        let pw: int = db_read_ident(sql, pp, kwbuf);
        if (pw >= 0 && db_kw(kwbuf, "WHERE") == 1) {
            let pcw: int = db_parse_where(sql, pw);
            if (pcw < 0) {
                return -1;
            }
            pp = pcw;
        }
        /* LIMIT */
        let pl: int = db_read_ident(sql, pp, kwbuf);
        if (pl >= 0 && db_kw(kwbuf, "LIMIT") == 1) {
            let pn: int = db_read_num(sql, pl, ptr_to_int(&db_parse_num));
            if (pn < 0) {
                return -1;
            }
            db_stmt_limit = db_parse_num;
            pp = pn;
        }
        /* TO JSON 必须位于 WHERE/LIMIT 之后。 */
        let pto: int = db_read_ident(sql, pp, kwbuf);
        if (pto >= 0 && db_kw(kwbuf, "TO") == 1) {
            let pj: int = db_read_ident(sql, pto, kwbuf);
            if (pj < 0 || db_kw(kwbuf, "JSON") == 0) {
                return -1;
            }
            db_stmt_to_json = 1;
        }
        db_stmt_kind = DbStmtKind.Select();
        return 0;
    }
    if (db_kw(kwbuf, "UPDATE") == 1) {
        /* UPDATE name SET col = v [WHERE ...] */
        let tname: u64 = ptr_to_int(&db_parse_table_buf[0]);
        let pt: int = db_read_ident(sql, p, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        let ps: int = db_read_ident(sql, pt, kwbuf);
        if (ps < 0 || db_kw(kwbuf, "SET") == 0) {
            return -1;
        }
        let cname: u64 = ptr_to_int(&db_parse_cols_buf[0][0]);
        let pc: int = db_read_ident(sql, ps, cname);
        if (pc < 0) {
            return -1;
        }
        db_stmt_cols[0] = cname;
        db_stmt_coln = 1;
        let peq: int = db_skip_sym(sql, pc, "=");
        if (peq < 0) {
            return -1;
        }
        let n: int = 0;
        let pn: int = db_read_num(sql, peq, ptr_to_int(&db_parse_num));
        if (pn >= 0) {
            db_stmt_vals[0] = DbValue.Int(db_parse_num);
        } else {
            let value_buf: u64 = ptr_to_int(&db_parse_vals_buf[0][0]);
            let pstr: int = db_read_str(sql, peq, value_buf);
            if (pstr >= 0) {
                db_stmt_vals[0] = DbValue.Text(db_parse_text(value_buf));
                pn = pstr;
            } else {
                return -1;
            }
        }
        db_stmt_valn = 1;
        let pp: int = pn;
        let pw: int = db_read_ident(sql, pp, kwbuf);
        if (pw >= 0 && db_kw(kwbuf, "WHERE") == 1) {
            let pcw: int = db_parse_where(sql, pw);
            if (pcw < 0) {
                return -1;
            }
        }
        db_stmt_kind = DbStmtKind.Update();
        return 0;
    }
    if (db_kw(kwbuf, "DELETE") == 1) {
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0 || db_kw(kwbuf, "FROM") == 0) {
            return -1;
        }
        let tname: u64 = ptr_to_int(&db_parse_table_buf[0]);
        let pt: int = db_read_ident(sql, pb, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        let pp: int = pt;
        let pw: int = db_read_ident(sql, pp, kwbuf);
        if (pw >= 0 && db_kw(kwbuf, "WHERE") == 1) {
            let pcw: int = db_parse_where(sql, pw);
            if (pcw < 0) {
                return -1;
            }
        }
        db_stmt_kind = DbStmtKind.Delete();
        return 0;
    }
    return -1;
}
