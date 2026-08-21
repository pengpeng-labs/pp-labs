/* Typed ppos facade over the independently usable ppdb core. */

struct DbTableHandle {
    id: int,
}

static database_schema_scratch: [2048]u8;

fn database_table(name: u64) -> DbTableHandle {
    let table: DbTableHandle;
    table.id = db_find_table(int_to_ptr(name));
    return table;
}

fn database_table_is_valid(table: DbTableHandle) -> bool {
    return table.id >= 0;
}

fn database_create(name: u64, ncols: int, t0: int, t1: int, t2: int, t3: int) -> DbTableHandle {
    let table: DbTableHandle;
    table.id = db_create_table(int_to_ptr(name), ncols, t0, t1, t2, t3);
    return table;
}

fn database_drop(table: DbTableHandle) -> bool {
    if (!database_table_is_valid(table)) {
        return false;
    }
    return db_drop_table(table.id) == 0;
}

fn database_insert(table: DbTableHandle, values: u64) -> bool {
    if (!database_table_is_valid(table)) {
        return false;
    }
    return db_insert(table.id, values) >= 0;
}

fn database_schema(destination: u64) -> int {
    return db_schema_to_buf(destination as int);
}

fn database_write_schema(writer: *BoundedWriter) -> bool {
    let size: int = db_schema_to_buf(ptr_to_int(&database_schema_scratch[0]) as int);
    return writer_write_bytes(writer, ptr_to_int(&database_schema_scratch[0]), size);
}

fn database_kv_read(key: u64, destination: u64) -> ServiceBytes {
    let result: ServiceBytes = service_bytes_empty();
    result.len = kv_get(key, destination);
    if (result.len >= 0) {
        result.data = destination;
        result.ok = true;
    }
    return result;
}

fn database_kv_write(key: u64, value: u64) -> bool {
    return kv_put(key, value) == 1;
}

fn database_kv_remove(key: u64) -> bool {
    return kv_del(key) == 1;
}

fn database_doc_read(name: u64, destination: u64) -> ServiceBytes {
    let result: ServiceBytes = service_bytes_empty();
    result.len = doc_get(name, destination);
    if (result.len >= 0) {
        result.data = destination;
        result.ok = true;
    }
    return result;
}

fn database_doc_write(name: u64, content: u64) -> bool {
    return doc_put(name, content) == 1;
}

fn database_save(name: u64) {
    db_save(name);
}

fn database_load(name: u64) {
    db_load(name);
}

fn database_list() {
    db_list();
}

fn database_execute_console(sql: u64) -> bool {
    if (db_parse_sql(sql) < 0) {
        console_write("sql: syntax error\n");
        return false;
    }
    if (db_stmt_is_create() || db_stmt_is_tx()) {
        return db_exec(-1) == 0;
    }
    let table: DbTableHandle = database_table(db_stmt_table);
    if (!database_table_is_valid(table)) {
        console_write("sql: no such table\n");
        return false;
    }
    return db_exec(table.id) == 0;
}

fn database_emit(destination: u64, capacity: int, message: str) -> int {
    let size: int = len(message) as int;
    if (capacity <= 0) {
        return 0;
    }
    if (size >= capacity) {
        size = capacity - 1;
    }
    let i: int = 0;
    while (i < size) {
        volatile_store8(destination + i, message[i]);
        i = i + 1;
    }
    volatile_store8(destination + size, 0);
    return size;
}

fn database_execute_to_buffer(sql: u64, output: u64, capacity: int) -> int {
    if (db_parse_sql(sql) < 0) {
        return database_emit(output, capacity, "sql: syntax error\n");
    }
    if (db_stmt_is_tx()) {
        switch db_stmt_kind {
            DbStmtKind.Begin {
                if (db_tx_begin()) { return database_emit(output, capacity, "transaction begun\n"); }
                return database_emit(output, capacity, "transaction already active\n");
            }
            DbStmtKind.Commit {
                if (db_tx_commit()) { return database_emit(output, capacity, "transaction committed\n"); }
                return database_emit(output, capacity, "no active transaction\n");
            }
            DbStmtKind.Rollback {
                if (db_tx_rollback()) { return database_emit(output, capacity, "transaction rolled back\n"); }
                return database_emit(output, capacity, "no active transaction\n");
            }
            _ { return database_emit(output, capacity, "sql: unsupported\n"); }
        }
    }
    if (db_stmt_is_create()) {
        if (db_stmt_is_create_index()) {
            let table: DbTableHandle = database_table(db_stmt_table);
            if (!database_table_is_valid(table)) { return database_emit(output, capacity, "sql: no such table\n"); }
            let col: int = db_col_idx(table.id, db_stmt_cols[0]);
            if (col < 0) { return database_emit(output, capacity, "sql: no such column\n"); }
            if (db_index_create(db_stmt_index, table.id, col) < 0) {
                return database_emit(output, capacity, "create index failed\n");
            }
            return database_emit(output, capacity, "index created\n");
        }
        let table: DbTableHandle = database_create(db_stmt_table, db_stmt_coln,
            db_stmt_types[0], db_stmt_types[1], db_stmt_types[2], db_stmt_types[3]);
        if (database_table_is_valid(table)) {
            db_set_col_names(table.id, db_stmt_cols[0], db_stmt_cols[1], db_stmt_cols[2], db_stmt_cols[3]);
            return database_emit(output, capacity, "table created\n");
        }
        return database_emit(output, capacity, "create failed\n");
    }
    if (db_stmt_is_drop()) {
        let table: DbTableHandle = database_table(db_stmt_table);
        if (database_drop(table)) {
            return database_emit(output, capacity, "table dropped\n");
        }
        return database_emit(output, capacity, "sql: no such table\n");
    }
    let table: DbTableHandle = database_table(db_stmt_table);
    if (!database_table_is_valid(table)) {
        return database_emit(output, capacity, "sql: no such table\n");
    }
    switch db_stmt_kind {
        DbStmtKind.Select { return db_select_to_buf(table.id, output, capacity); }
        DbStmtKind.Insert {
            db_exec_insert(table.id);
            return database_emit(output, capacity, "1 row inserted\n");
        }
        DbStmtKind.Update {
            db_exec_update(table.id);
            return database_emit(output, capacity, "updated\n");
        }
        DbStmtKind.Delete {
            db_exec_delete(table.id);
            return database_emit(output, capacity, "deleted\n");
        }
        _ { return database_emit(output, capacity, "sql: unsupported\n"); }
    }
}
