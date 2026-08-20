/* db_sql_parse.pp：SQL 子集解析器（token 化 + 语句结构提取）
   支持：CREATE TABLE / DROP TABLE / INSERT INTO / SELECT(WHERE/LIMIT) / UPDATE / DELETE */

/* 解析结果（全局状态，执行器读取） */
static db_stmt_type: int = -1;        /* 0=create 1=insert 2=select 3=update 4=delete 5=drop */
static db_stmt_table: int = 0;        /* 表名指针 */
static db_stmt_cols: [4]int;        /* 列名指针 */
static db_stmt_coln: int = 0;
static db_stmt_types: [4]int;       /* create 的列类型（0=int 1=str） */
static db_stmt_vals: [4]int;        /* 值（int 值或字符串指针） */
static db_stmt_valn: int = 0;
static db_stmt_where_col: int = 0;    /* where 列名指针（0=无） */
static db_stmt_where_op: int = 0;     /* 0=eq 1=ne 2=lt 3=gt 4=le 5=ge */
static db_stmt_where_val: int = 0;    /* where 值（int 或字符串指针） */
static db_stmt_where_isstr: int = 0;  /* where 值是否为字符串 */
static db_stmt_limit: int = 0;        /* 0=不限 */
static db_stmt_star: int = 0;         /* SELECT * 通配符（1=展开所有列） */

/* ---- token 化辅助 ---- */

/* 跳过空白，返回下一 token 位置 */
fn db_skip_ws(sql: int, pos: int) -> int {
    while (volatile_load8(sql + pos) == 32 || volatile_load8(sql + pos) == 9) {
        pos = pos + 1;
    }
    return pos;
}

/* 读标识符到 buf（≤31），返回下一位置；无标识符返回 -1 */
fn db_read_ident(sql: int, pos: int, buf: int) -> int {
    let p: int = db_skip_ws(sql, pos);
    let c: int = volatile_load8(sql + p);
    if (!((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95)) {
        return -1;
    }
    let o: int = 0;
    while ((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95) {
        volatile_store8(buf + o, c);
        o = o + 1;
        p = p + 1;
        c = volatile_load8(sql + p);
    }
    volatile_store8(buf + o, 0);
    return p;
}

/* 读数字（int），返回下一位置；无数字返回 -1 */
fn db_read_num(sql: int, pos: int, out: int) -> int {
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

/* 读字符串字面量（'...'），存到 0x406800（拷贝），返回下一位置 */
fn db_read_str(sql: int, pos: int) -> int {
    let p: int = db_skip_ws(sql, pos);
    if (volatile_load8(sql + p) != 39) {   /* ' */
        return -1;
    }
    p = p + 1;
    let o: int = 0;
    while (volatile_load8(sql + p) != 39 && volatile_load8(sql + p) != 0) {
        volatile_store8(0x406800 + o, volatile_load8(sql + p));
        o = o + 1;
        p = p + 1;
    }
    volatile_store8(0x406800 + o, 0);
    return p + 1;
}

/* 跳过符号（返回下一位置）；不匹配返回 -1 */
fn db_skip_sym(sql: int, pos: int, sym: str) -> int {
    let p: int = db_skip_ws(sql, pos);
    let i: int = 0;
    while (sym[i] != 0) {
        if (volatile_load8(sql + p + i) != sym[i]) {
            return -1;
        }
        i = i + 1;
    }
    return p + i;
}

/* 比较 buf 处标识符与字面量（大小写不敏感） */
fn db_kw(buf: int, kw: str) -> int {
    let i: int = 0;
    while (kw[i] != 0) {
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
    return 1;
}

/* ---- 主解析 ---- */

/* 解析 WHERE 条件：返回下一位置；cond_col/op/val/isstr 写入全局 */
fn db_parse_where(sql: int, pos: int) -> int {
    let colbuf: int = 0x406000;
    let p: int = db_read_ident(sql, pos, colbuf);
    if (p < 0) {
        return -1;
    }
    db_stmt_where_col = 0x406000;
    /* 操作符 */
    let p2: int = db_skip_sym(sql, p, "!=");
    if (p2 >= 0) {
        db_stmt_where_op = 1;
    } else {
        p2 = db_skip_sym(sql, p, "<=");
        if (p2 >= 0) {
            db_stmt_where_op = 4;
        } else {
            p2 = db_skip_sym(sql, p, ">=");
            if (p2 >= 0) {
                db_stmt_where_op = 5;
            } else {
                p2 = db_skip_sym(sql, p, "<");
                if (p2 >= 0) {
                    db_stmt_where_op = 2;
                } else {
                    p2 = db_skip_sym(sql, p, ">");
                    if (p2 >= 0) {
                        db_stmt_where_op = 3;
                    } else {
                        p2 = db_skip_sym(sql, p, "=");
                        if (p2 >= 0) {
                            db_stmt_where_op = 0;
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
    let p3: int = db_read_num(sql, p2, 0x406100);
    if (p3 >= 0) {
        db_stmt_where_val = volatile_load32(0x406100);
        db_stmt_where_isstr = 0;
    } else {
        let p4: int = db_read_str(sql, p2);
        if (p4 >= 0) {
            db_stmt_where_val = 0x406800;
            db_stmt_where_isstr = 1;
            p3 = p4;
        } else {
            return -1;
        }
    }
    return p3;
}

/* 解析 SQL 语句（sql 指向文本），填充全局；返回语句类型，-1 错误 */
fn db_parse_sql(sql: int) -> int {
    db_stmt_type = -1;
    db_stmt_coln = 0;
    db_stmt_valn = 0;
    db_stmt_where_col = 0;
    db_stmt_limit = 0;
    db_stmt_star = 0;
    let kwbuf: int = 0x406200;
    let p: int = db_read_ident(sql, 0, kwbuf);
    if (p < 0) {
        return -1;
    }
    if (db_kw(kwbuf, "CREATE") == 1) {
        /* CREATE TABLE name (col TYPE, ...) */
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0 || db_kw(kwbuf, "TABLE") == 0) {
            return -1;
        }
        let tname: int = 0x407000;
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
            let cname: int = 0x406400 + db_stmt_coln * 40;
            let pc: int = db_read_ident(sql, ps, cname);
            if (pc < 0) {
                return -1;
            }
            db_stmt_cols[db_stmt_coln] = cname;
            let tname2: int = 0x406300;
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
                    let pn: int = db_read_num(sql, ps2, 0x406100);
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
        db_stmt_type = 0;
        return 0;
    }
    if (db_kw(kwbuf, "DROP") == 1) {
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0 || db_kw(kwbuf, "TABLE") == 0) {
            return -1;
        }
        let tname: int = 0x407000;
        let pt: int = db_read_ident(sql, pb, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        db_stmt_type = 5;
        return 0;
    }
    if (db_kw(kwbuf, "INSERT") == 1) {
        /* INSERT INTO name (col, ...) VALUES (v, ...) */
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0 || db_kw(kwbuf, "INTO") == 0) {
            return -1;
        }
        let tname: int = 0x407000;
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
            let cname: int = 0x406400 + db_stmt_coln * 40;
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
            let pn: int = db_read_num(sql, ps2, 0x406100);
            if (pn >= 0) {
                db_stmt_vals[db_stmt_valn] = volatile_load32(0x406100);
            } else {
                let pstr: int = db_read_str(sql, ps2);
                if (pstr >= 0) {
                    db_stmt_vals[db_stmt_valn] = 0x406800;
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
        db_stmt_type = 1;
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
                let cname: int = 0x406400 + db_stmt_coln * 40;
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
        let tname: int = 0x407000;
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
            let pn: int = db_read_num(sql, pl, 0x406100);
            if (pn < 0) {
                return -1;
            }
            db_stmt_limit = volatile_load32(0x406100);
        }
        db_stmt_type = 2;
        return 0;
    }
    if (db_kw(kwbuf, "UPDATE") == 1) {
        /* UPDATE name SET col = v [WHERE ...] */
        let tname: int = 0x407000;
        let pt: int = db_read_ident(sql, p, tname);
        if (pt < 0) {
            return -1;
        }
        db_stmt_table = tname;
        let ps: int = db_read_ident(sql, pt, kwbuf);
        if (ps < 0 || db_kw(kwbuf, "SET") == 0) {
            return -1;
        }
        let cname: int = 0x406400;
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
        let pn: int = db_read_num(sql, peq, 0x406100);
        if (pn >= 0) {
            db_stmt_vals[0] = volatile_load32(0x406100);
        } else {
            let pstr: int = db_read_str(sql, peq);
            if (pstr >= 0) {
                db_stmt_vals[0] = 0x406800;
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
        db_stmt_type = 3;
        return 0;
    }
    if (db_kw(kwbuf, "DELETE") == 1) {
        let pb: int = db_read_ident(sql, p, kwbuf);
        if (pb < 0 || db_kw(kwbuf, "FROM") == 0) {
            return -1;
        }
        let tname: int = 0x407000;
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
        db_stmt_type = 4;
        return 0;
    }
    return -1;
}
