/* db_tx.pp：单会话事务。数据库级 before-image 是一条粗粒度 UNDO 记录。 */

static db_tx_active: bool = false;
static db_tx_table_lock: [8]int;

static db_tx_ntables: int = 0;
static db_tx_tname: [8][32]u8;
static db_tx_tcol: [8][4][32]u8;
static db_tx_tcols: [8]int;
static db_tx_ttypes: [8][4]int;
static db_tx_tfirst: [8]int;
static db_tx_tlast: [8]int;
static db_tx_next_page: int = 0;
static db_tx_free_n: int = 0;
static db_tx_free_list: [128]int;
static db_tx_next_rowid: int = 1;
static db_tx_pages: [65536]u8;

static db_tx_kv_count: int = 0;
static db_tx_kv_keys: [64][32]u8;
static db_tx_kv_vals: [64][64]u8;
static db_tx_doc_count: int = 0;
static db_tx_doc_names: [16][32]u8;
static db_tx_doc_cont: [16][128]u8;

static db_tx_nindexes: int = 0;
static db_tx_idx_name: [8][32]u8;
static db_tx_idx_tid: [8]int;
static db_tx_idx_col: [8]int;

fn db_tx_copy(dst: u64, src: u64, n: int) {
    let i: int = 0;
    while (i < n) {
        volatile_store8(dst + i, volatile_load8(src + i));
        i = i + 1;
    }
}

fn db_tx_begin() -> bool {
    if (db_tx_active) { return false; }
    db_tx_ntables = db_ntables;
    let t: int = 0;
    while (t < 8) {
        db_tx_copy(ptr_to_int(&db_tx_tname[t][0]), ptr_to_int(&db_tname_buf[t][0]), 32);
        db_tx_tcols[t] = db_tcols[t];
        db_tx_tfirst[t] = db_tfirst[t];
        db_tx_tlast[t] = db_tlast[t];
        db_tx_table_lock[t] = 1;
        let c: int = 0;
        while (c < 4) {
            db_tx_copy(ptr_to_int(&db_tx_tcol[t][c][0]), ptr_to_int(&db_tcol_buf[t][c][0]), 32);
            db_tx_ttypes[t][c] = db_ttypes[t][c];
            c = c + 1;
        }
        t = t + 1;
    }
    db_tx_next_page = db_next_page;
    db_tx_free_n = db_free_n;
    db_tx_next_rowid = db_next_rowid;
    let f: int = 0;
    while (f < 128) {
        db_tx_free_list[f] = db_free_list[f];
        f = f + 1;
    }
    db_tx_copy(ptr_to_int(&db_tx_pages[0]), db_page_ptr(1), DB_NPAGES * DB_PAGE_SIZE);

    db_tx_kv_count = kv_count;
    let i: int = 0;
    while (i < 64) {
        db_tx_copy(ptr_to_int(&db_tx_kv_keys[i][0]), ptr_to_int(&kv_keys[i][0]), 32);
        db_tx_copy(ptr_to_int(&db_tx_kv_vals[i][0]), ptr_to_int(&kv_vals[i][0]), 64);
        i = i + 1;
    }
    db_tx_doc_count = doc_count;
    i = 0;
    while (i < 16) {
        db_tx_copy(ptr_to_int(&db_tx_doc_names[i][0]), ptr_to_int(&doc_names[i][0]), 32);
        db_tx_copy(ptr_to_int(&db_tx_doc_cont[i][0]), ptr_to_int(&doc_cont[i][0]), 128);
        i = i + 1;
    }
    db_tx_nindexes = db_nindexes;
    i = 0;
    while (i < 8) {
        db_tx_copy(ptr_to_int(&db_tx_idx_name[i][0]), ptr_to_int(&db_idx_name[i][0]), 32);
        db_tx_idx_tid[i] = db_idx_tid[i];
        db_tx_idx_col[i] = db_idx_col[i];
        i = i + 1;
    }
    db_tx_active = true;
    return true;
}

fn db_tx_unlock() {
    let i: int = 0;
    while (i < 8) {
        db_tx_table_lock[i] = 0;
        i = i + 1;
    }
    db_tx_active = false;
}

fn db_tx_commit() -> bool {
    if (!db_tx_active) { return false; }
    db_tx_unlock();
    return true;
}

fn db_tx_rollback() -> bool {
    if (!db_tx_active) { return false; }
    db_ntables = db_tx_ntables;
    let t: int = 0;
    while (t < 8) {
        db_tx_copy(ptr_to_int(&db_tname_buf[t][0]), ptr_to_int(&db_tx_tname[t][0]), 32);
        db_tname[t] = ptr_to_int(&db_tname_buf[t][0]);
        db_tcols[t] = db_tx_tcols[t];
        db_tfirst[t] = db_tx_tfirst[t];
        db_tlast[t] = db_tx_tlast[t];
        db_set_default_col_names(t);
        let c: int = 0;
        while (c < 4) {
            db_tx_copy(ptr_to_int(&db_tcol_buf[t][c][0]), ptr_to_int(&db_tx_tcol[t][c][0]), 32);
            db_ttypes[t][c] = db_tx_ttypes[t][c];
            c = c + 1;
        }
        t = t + 1;
    }
    db_next_page = db_tx_next_page;
    db_free_n = db_tx_free_n;
    db_next_rowid = db_tx_next_rowid;
    let f: int = 0;
    while (f < 128) {
        db_free_list[f] = db_tx_free_list[f];
        f = f + 1;
    }
    db_tx_copy(db_page_ptr(1), ptr_to_int(&db_tx_pages[0]), DB_NPAGES * DB_PAGE_SIZE);
    db_rebuild_rowids();

    kv_count = db_tx_kv_count;
    let i: int = 0;
    while (i < 64) {
        db_tx_copy(ptr_to_int(&kv_keys[i][0]), ptr_to_int(&db_tx_kv_keys[i][0]), 32);
        db_tx_copy(ptr_to_int(&kv_vals[i][0]), ptr_to_int(&db_tx_kv_vals[i][0]), 64);
        i = i + 1;
    }
    doc_count = db_tx_doc_count;
    i = 0;
    while (i < 16) {
        db_tx_copy(ptr_to_int(&doc_names[i][0]), ptr_to_int(&db_tx_doc_names[i][0]), 32);
        db_tx_copy(ptr_to_int(&doc_cont[i][0]), ptr_to_int(&db_tx_doc_cont[i][0]), 128);
        i = i + 1;
    }
    db_nindexes = db_tx_nindexes;
    i = 0;
    while (i < 8) {
        db_tx_copy(ptr_to_int(&db_idx_name[i][0]), ptr_to_int(&db_tx_idx_name[i][0]), 32);
        db_idx_tid[i] = db_tx_idx_tid[i];
        db_idx_col[i] = db_tx_idx_col[i];
        i = i + 1;
    }
    db_index_rebuild_all();
    db_tx_unlock();
    return true;
}
