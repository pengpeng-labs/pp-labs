/* host_ppos.pp：pp-db 的 pp-os 宿主——页提供者用固定内存页区（0x680000，128×512B） */

static db_next_page: int = 0;
static db_free_list: [128]int;
static db_free_n: int = 0;

fn db_page_alloc() -> int {
    if (db_free_n > 0) {
        db_free_n = db_free_n - 1;
        return db_free_list[db_free_n];
    }
    if (db_next_page < DB_NPAGES) {
        let r: int = db_next_page + 1;   /* 页号从 1 起（0 = 无页/结束标记） */
        db_next_page = db_next_page + 1;
        return r;
    }
    return -1;
}

fn db_page_ptr(n: int) -> u64 {
    return 0x680000 + n * DB_PAGE_SIZE;
}

fn db_page_dirty(n: int) {
    /* 内存宿主无需写回 */
}

/* 释放页（进空闲链，供复用） */
fn db_page_free(n: int) {
    if (db_free_n < 128) {
        db_free_list[db_free_n] = n;
        db_free_n = db_free_n + 1;
    }
}
