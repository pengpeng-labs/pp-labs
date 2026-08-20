/* host_native.pp：pp-db 宿主机宿主——页提供者用静态缓冲（经 pp 编译器在宿主机运行） */

static db_next_page: int = 0;
static db_pages: [65536]u8;   /* 128 页 × 512B */
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
    /* 页号 0 是链尾哨兵；物理页区从逻辑页 1 开始连续存放。 */
    return ptr_to_int(&db_pages[0]) + (n - 1) * DB_PAGE_SIZE;
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
