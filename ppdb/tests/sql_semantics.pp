import "../db_core.pp";
import "../db_sql_parse.pp";
import "../db_sql_exec.pp";
import "../db_kv.pp";
import "../db_doc.pp";
import "../db_tx.pp";
import "../host_native.pp";

extern fn putchar(c: int) -> int;

fn serial_putc(c: int) {
    putchar(c);
}

fn serial_print(s: str) {
    let i: int = 0;
    while (i < len(s) as int) {
        serial_putc(s[i]);
        i = i + 1;
    }
}

fn print_int(n: int) {
    if (n == 0) {
        serial_putc(48);
        return;
    }
    let digits: [12]u8;
    let i: int = 0;
    while (n > 0) {
        digits[i] = 48 + n % 10;
        n = n / 10;
        i = i + 1;
    }
    while (i > 0) {
        i = i - 1;
        serial_putc(digits[i]);
    }
}

fn cstr_eq(p: u64, expected: str) -> bool {
    let n: int = len(expected) as int;
    let i: int = 0;
    while (i < n) {
        if (volatile_load8(p + i) != expected[i]) {
            return false;
        }
        i = i + 1;
    }
    return volatile_load8(p + n) == 0;
}

fn parse(sql: str) -> int {
    return db_parse_sql(ptr_to_int(sql));
}

fn main() -> int {
    if (parse("CREATE TABLE people (id INT, name STR, city STR)") < 0) {
        return 1;
    }
    if (db_exec(-1) != 0) {
        return 2;
    }
    let tid: int = db_find_table("people");
    if (tid < 0 || db_col_idx(tid, ptr_to_int("name")) != 1
        || db_col_idx(tid, ptr_to_int("city")) != 2) {
        return 3;
    }
    if (db_create_table("people", 1, 0, 0, 0, 0) != -1) {
        return 18;
    }
    if (parse("INSERT INTO people (city,id,name) VALUES ('Paris',7,'Ada')") < 0) {
        return 4;
    }
    db_exec(tid);
    let scan: DbScan = db_scan_open(tid);
    let rec: u64 = db_scan_next(&scan);
    if (rec == 0 || db_col(rec, tid, 0) != 7
        || !cstr_eq(db_col(rec, tid, 1), "Ada")
        || !cstr_eq(db_col(rec, tid, 2), "Paris")) {
        return 5;
    }
    if (parse("INSERT INTO people (id,name,city) VALUES (8,'Bob','Rome')") < 0) {
        return 10;
    }
    db_exec(tid);
    /* 两个扫描器交错前进，状态必须互不影响。 */
    let left: DbScan = db_scan_open(tid);
    let right: DbScan = db_scan_open(tid);
    let left_rec: u64 = db_scan_next(&left);
    let right_rec: u64 = db_scan_next(&right);
    if (db_col(left_rec, tid, 0) != 7 || db_col(right_rec, tid, 0) != 7) {
        return 11;
    }
    left_rec = db_scan_next(&left);
    right_rec = db_scan_next(&right);
    if (db_col(left_rec, tid, 0) != 8 || db_col(right_rec, tid, 0) != 8) {
        return 12;
    }
    if (parse("UPDATE people SET city='London' WHERE name='Ada'") < 0) {
        return 6;
    }
    db_exec(tid);
    scan = db_scan_open(tid);
    rec = db_scan_next(&scan);
    if (rec == 0 || !cstr_eq(db_col(rec, tid, 2), "London")) {
        return 7;
    }
    if (parse("SELECT city,id FROM people WHERE name='Ada'") < 0) {
        return 8;
    }
    if (db_stmt_coln != 2 || db_col_idx(tid, db_stmt_cols[0]) != 2
        || db_col_idx(tid, db_stmt_cols[1]) != 0 || db_match(rec, tid) != 1) {
        return 9;
    }
    if (parse("SELECT city,id FROM people WHERE name='Ada' TO JSON") < 0) {
        return 16;
    }
    let json: [128]u8;
    db_select_to_buf(tid, ptr_to_int(&json[0]), 128);
    if (!cstr_eq(ptr_to_int(&json[0]), "[{\"city\":\"London\",\"id\":7}]\n")) {
        return 17;
    }
    if (parse("CREATE INDEX people_id ON people(id)") < 0 || db_exec(-1) != 0) {
        return 19;
    }
    if (db_nindexes != 1 || db_idx_count[0] != 2
        || db_idx_keys[0][0] != 7 || db_idx_keys[0][1] != 8) {
        return 20;
    }
    if (parse("SELECT id,name FROM people WHERE id>=8") < 0) { return 21; }
    let indexed: DbRowCursor = db_row_cursor_open(tid);
    let indexed_rec: u64 = db_row_cursor_next(&indexed);
    if (db_last_plan_index != 0 || indexed_rec == 0 || db_col(indexed_rec, tid, 0) != 8) {
        return 22;
    }
    if (parse("UPDATE people SET id=9 WHERE name='Bob'") < 0) { return 23; }
    db_exec(tid);
    if (db_idx_keys[0][1] != 9) { return 24; }
    if (parse("DELETE FROM people WHERE id=7") < 0) { return 25; }
    db_exec(tid);
    if (db_idx_count[0] != 1 || db_idx_keys[0][0] != 9) { return 26; }
    if (parse("BEGIN") < 0 || db_exec(-1) != 0) { return 27; }
    if (parse("INSERT INTO people (id,name,city) VALUES (10,'Tx','Temp')") < 0) { return 28; }
    db_exec(tid);
    kv_put(ptr_to_int("tx-key"), ptr_to_int("tx-value"));
    doc_put(ptr_to_int("tx-doc"), ptr_to_int("{\"open\":true}"));
    if (db_create_table("tx_table", 1, 0, 0, 0, 0) < 0) { return 29; }
    if (parse("ROLLBACK") < 0 || db_exec(-1) != 0) { return 30; }
    let tx_buf: [128]u8;
    if (db_find_table("tx_table") >= 0 || kv_get(ptr_to_int("tx-key"), ptr_to_int(&tx_buf[0])) >= 0
        || doc_get(ptr_to_int("tx-doc"), ptr_to_int(&tx_buf[0])) >= 0
        || db_idx_count[0] != 1 || db_idx_keys[0][0] != 9) {
        return 31;
    }
    if (parse("BEGIN") < 0 || db_exec(-1) != 0) { return 32; }
    if (parse("UPDATE people SET id=11 WHERE id=9") < 0) { return 33; }
    db_exec(tid);
    if (parse("COMMIT") < 0 || db_exec(-1) != 0 || db_idx_keys[0][0] != 11) {
        return 34;
    }
    let overflow_vals: [4]u64;
    let overflow_name: str = "overflow";
    let overflow_city: str = "buffer-city";
    let extra: int = 0;
    while (extra < 8) {
        overflow_vals[0] = (20 + extra) as u64;
        overflow_vals[1] = ptr_to_int(overflow_name);
        overflow_vals[2] = ptr_to_int(overflow_city);
        if (db_insert(tid, ptr_to_int(&overflow_vals[0])) != 1) { return 35; }
        extra = extra + 1;
    }
    if (parse("SELECT id,name,city FROM people TO JSON") < 0) { return 36; }
    let small_out: [64]u8;
    db_select_to_buf(tid, ptr_to_int(&small_out[0]), 64);
    if (!cstr_eq(ptr_to_int(&small_out[0]), "sql: result too large\n")) { return 37; }
    /* 删除后页内空间与 slot 都必须复用。 */
    let churn: int = db_create_table("churn", 1, 0, 0, 0, 0);
    let vals: [4]u64;
    let round: int = 0;
    while (round < 200) {
        vals[0] = round as u64;
        if (db_insert(churn, ptr_to_int(&vals[0])) != 1) {
            return 13;
        }
        let churn_scan: DbScan = db_scan_open(churn);
        if (db_scan_next(&churn_scan) == 0) {
            return 14;
        }
        db_scan_delete(&churn_scan);
        round = round + 1;
    }
    if (db_next_page != 3) {
        return 15;
    }
    return 0;
}
