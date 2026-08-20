/* db_core.pp：pp-db 存储内核——页式堆表（页链 + slot array）+ 记录管理（宿主无关）
   页提供者接口由宿主实现（host_ppos.pp / host_native.pp）：
     fn db_page_alloc() -> int;      分配页，返回页号（-1 表示满）
     fn db_page_ptr(n: int) -> u64;  页 n 的内存指针（地址通道 64 位，宿主高地址可用）
     fn db_page_dirty(n: int);       标记页脏（宿主机写回用） */

static DB_PAGE_SIZE: int = 512;
static DB_NPAGES: int = 128;

/* ---- 表目录（≤8 表，每表 ≤4 列）---- */
static db_ntables: int = 0;
static db_tname_buf: [8][32]u8;   /* 表名稳定存储（目录存指针，指向这里） */
static db_tname: [8]u64;
static db_tcol_buf: [8][4][32]u8; /* 列名稳定存储 */
static db_tcol: [8][4]u64;
static db_tcols: [8]int;
static db_ttypes: [8][4]int;   /* 0=int(4B) 1=str(32B) */
static db_tfirst: [8]int;      /* 首页号 */
static db_tlast: [8]int;       /* 尾页号 */
static db_next_rowid: int = 1;  /* slot meta 高 16 位；0 保留给旧镜像迁移 */
static db_row_ptr: [32768]u64;   /* rowid -> 当前记录地址；压缩/load 后重建 */

fn db_slot_meta(rowid: int, len: int) -> int {
    return rowid * 65536 + len;
}

fn db_slot_len(meta: int) -> int {
    return meta % 65536;
}

fn db_slot_rowid(meta: int) -> int {
    return meta / 65536;
}

/* 过渡兼容：v0.3 str 正常携带长度；CLI 的旧命令缓冲仍以长度 0 的裸视图传入。 */
fn db_name_len(name: str) -> int {
    let n: int = len(name) as int;
    if (n > 0) {
        return n;
    }
    let p: u64 = ptr_to_int(name);
    while (n < 31 && volatile_load8(p + n) != 0) {
        n = n + 1;
    }
    return n;
}

fn db_copy_name(dst: u64, src: u64) {
    let i: int = 0;
    while (i < 32) {
        volatile_store8(dst + i, 0);
        i = i + 1;
    }
    i = 0;
    while (i < 31 && volatile_load8(src + i) != 0) {
        volatile_store8(dst + i, volatile_load8(src + i));
        i = i + 1;
    }
}

fn db_set_default_col_names(tid: int) {
    let i: int = 0;
    while (i < 4) {
        let dst: u64 = ptr_to_int(&db_tcol_buf[tid][i][0]);
        volatile_store8(dst, 99); /* c */
        volatile_store8(dst + 1, 48 + i);
        volatile_store8(dst + 2, 0);
        db_tcol[tid][i] = dst;
        i = i + 1;
    }
}

fn db_set_col_names(tid: int, c0: u64, c1: u64, c2: u64, c3: u64) {
    let names: [4]u64;
    names[0] = c0;
    names[1] = c1;
    names[2] = c2;
    names[3] = c3;
    let i: int = 0;
    while (i < db_tcols[tid]) {
        if (names[i] != 0) {
            db_copy_name(db_tcol[tid][i], names[i]);
        }
        i = i + 1;
    }
}

/* 记录大小（字节） */
fn db_rec_size(tid: int) -> int {
    let s: int = 0;
    let i: int = 0;
    while (i < db_tcols[tid]) {
        if (db_ttypes[tid][i] == 0) {
            s = s + 4;
        } else {
            s = s + 32;
        }
        i = i + 1;
    }
    return s;
}

/* 页 header 布局：0:页号 4:表号 8:slot 数 12:空闲指针 16:下一页 */
fn db_page_init(pg: int, tid: int) {
    let p: u64 = db_page_ptr(pg);
    volatile_store32(p, pg);
    volatile_store32(p + 4, tid);
    volatile_store32(p + 8, 0);
    volatile_store32(p + 12, 512);
    volatile_store32(p + 16, 0);
    db_page_dirty(pg);
}

/* 建表：name + ncols 列（类型 t0..t3，0=int 1=str；多余列忽略） */
fn db_create_table(name: str, ncols: int, t0: int, t1: int, t2: int, t3: int) -> int {
    if (db_ntables >= 8 || ncols < 1 || ncols > 4 || db_name_len(name) == 0
        || db_find_table(name) >= 0) {
        return -1;
    }
    let tid: int = db_ntables;
    /* 表名拷入稳定存储（目录只存指针，避免指向命令缓冲） */
    let name_len: int = db_name_len(name);
    let copy_len: int = name_len;
    if (copy_len > 31) {
        copy_len = 31;
    }
    let j: int = 0;
    while (j < 32) {
        db_tname_buf[tid][j] = 0;
        j = j + 1;
    }
    j = 0;
    while (j < copy_len) {
        db_tname_buf[tid][j] = name[j];
        j = j + 1;
    }
    db_tname[tid] = ptr_to_int(&db_tname_buf[tid][0]);
    db_set_default_col_names(tid);
    db_tcols[tid] = ncols;
    db_ttypes[tid][0] = t0;
    db_ttypes[tid][1] = t1;
    db_ttypes[tid][2] = t2;
    db_ttypes[tid][3] = t3;
    let pg: int = db_page_alloc();
    if (pg < 0) {
        return -1;
    }
    db_page_init(pg, tid);
    db_tfirst[tid] = pg;
    db_tlast[tid] = pg;
    db_ntables = db_ntables + 1;
    return tid;
}

/* 按名找表，返回 tid；未找到 -1 */
fn db_find_table(name: str) -> int {
    let name_len: int = db_name_len(name);
    if (name_len > 31) {
        return -1;
    }
    let i: int = 0;
    while (i < db_ntables) {
        let j: int = 0;
        let eq: int = 1;
        while (j < name_len) {
            let a: int = volatile_load8(db_tname[i] + j);
            let b: int = name[j];
            if (a != b) {
                eq = 0;
                break;
            }
            j = j + 1;
        }
        if (eq == 1 && volatile_load8(db_tname[i] + name_len) != 0) {
            eq = 0;
        }
        if (eq == 1) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

/* 删表：释放全部页 + 目录压缩（最后一个表移入空位）；返回 1 成功 */
fn db_drop_table(tid: int) -> int {
    if (tid < 0 || tid >= db_ntables) {
        return 0;
    }
    let pg: int = db_tfirst[tid];
    while (pg != 0) {
        let p: u64 = db_page_ptr(pg);
        let npg: int = volatile_load32(p + 16);
        let nslots: int = volatile_load32(p + 8);
        let si: int = 0;
        while (si < nslots) {
            let meta: int = volatile_load32(p + 40 + si * 8 + 4);
            let rowid: int = db_slot_rowid(meta);
            if (rowid > 0) { db_row_ptr[rowid] = 0; }
            si = si + 1;
        }
        db_page_free(pg);   /* 宿主实现：释放页进空闲链 */
        pg = npg;
    }
    let last: int = db_ntables - 1;
    db_index_on_drop(tid, last);
    if (last != tid) {
        let b: int = 0;
        while (b < 32) {
            db_tname_buf[tid][b] = db_tname_buf[last][b];
            if (db_tname_buf[last][b] == 0) {
                break;
            }
            b = b + 1;
        }
        db_tname[tid] = ptr_to_int(&db_tname_buf[tid][0]);
        db_tcols[tid] = db_tcols[last];
        let c: int = 0;
        while (c < 4) {
            db_ttypes[tid][c] = db_ttypes[last][c];
            db_copy_name(db_tcol[tid][c], db_tcol[last][c]);
            c = c + 1;
        }
        db_tfirst[tid] = db_tfirst[last];
        db_tlast[tid] = db_tlast[last];
        let moved_pg: int = db_tfirst[tid];
        while (moved_pg != 0) {
            let moved_ptr: u64 = db_page_ptr(moved_pg);
            volatile_store32(moved_ptr + 4, tid);
            db_page_dirty(moved_pg);
            moved_pg = volatile_load32(moved_ptr + 16);
        }
    }
    db_ntables = db_ntables - 1;
    return 1;
}

/* 表内某页剩余空间（收页地址；与宿主的 db_page_free 释放页区分） */
fn db_page_space(p: u64) -> int {
    let fp: int = volatile_load32(p + 12);
    let nslots: int = volatile_load32(p + 8);
    return fp - (40 + nslots * 8);
}

/* 插入一行：vals 指向值数组（[4]u64：每列一个 8 字节槽；str 列存指针）；返回 1 成功 */
fn db_insert(tid: int, vals: u64) -> int {
    let rsize: int = db_rec_size(tid);
    let pg: int = db_tlast[tid];
    let p: u64 = db_page_ptr(pg);
    /* 当前尾页空间不足则分配新页 */
    if (db_page_space(p) < rsize + 8) {
        let npg: int = db_page_alloc();
        if (npg < 0) {
            return 0;
        }
        db_page_init(npg, tid);
        volatile_store32(p + 16, npg);   /* 旧尾页 next = 新页 */
        db_page_dirty(pg);
        db_tlast[tid] = npg;
        pg = npg;
        p = db_page_ptr(pg);
    }
    /* 分配 slot */
    let nslots: int = volatile_load32(p + 8);
    let fp: int = volatile_load32(p + 12);
    let rec_off: int = fp - rsize;
    /* 写记录（槽宽 8B：int 列取低 32 位，str 列取 64 位指针） */
    let i: int = 0;
    let off2: int = 0;
    while (i < db_tcols[tid]) {
        let v: u64 = volatile_load64(vals + i * 8);
        if (db_ttypes[tid][i] == 0) {
            volatile_store32(p + rec_off + off2, v);
            off2 = off2 + 4;
        } else {
            let k: int = 0;
            while (k < 32) {
                volatile_store8(p + rec_off + off2 + k, 0);
                k = k + 1;
            }
            k = 0;
            while (k < 31 && volatile_load8(v + k) != 0) {
                volatile_store8(p + rec_off + off2 + k, volatile_load8(v + k));
                k = k + 1;
            }
            off2 = off2 + 32;
        }
        i = i + 1;
    }
    /* 写 slot（offset 在 slot 头部，length 在 +4） */
    let slot: u64 = p + 40 + nslots * 8;
    volatile_store32(slot, rec_off);
    if (db_next_rowid >= 32768) {
        return 0;
    }
    volatile_store32(slot + 4, db_slot_meta(db_next_rowid, rsize));
    db_row_ptr[db_next_rowid] = p + rec_off;
    db_next_rowid = db_next_rowid + 1;
    volatile_store32(p + 8, nslots + 1);
    volatile_store32(p + 12, rec_off);
    db_page_dirty(pg);
    db_index_rebuild_table(tid);
    return 1;
}

/* ---- 扫描迭代器 ---- */
struct DbScan {
    tid: int,
    page: int,
    slot: int,
    rowid: int,
}

fn db_scan_open(tid: int) -> DbScan {
    return DbScan { tid: tid, page: db_tfirst[tid], slot: 0, rowid: 0 };
}

/* 返回下一条记录数据指针（记录从字段 0 起）；无则 0 */
fn db_scan_next(scan: *DbScan) -> u64 {
    while (scan.page != 0) {
        let p: u64 = db_page_ptr(scan.page);
        let nslots: int = volatile_load32(p + 8);
        while (scan.slot < nslots) {
            let slot: u64 = p + 40 + scan.slot * 8;
            let off: int = volatile_load32(slot);
            let meta: int = volatile_load32(slot + 4);
            scan.slot = scan.slot + 1;
            if (off != 0) {
                scan.rowid = db_slot_rowid(meta);
                return p + off;
            }
        }
        scan.page = volatile_load32(p + 16);
        scan.slot = 0;
    }
    return 0;
}

fn db_col_ptr(rec: u64, tid: int, col: int) -> u64 {
    let off: int = 0;
    let i: int = 0;
    while (i < col) {
        if (db_ttypes[tid][i] == 0) {
            off = off + 4;
        } else {
            off = off + 32;
        }
        i = i + 1;
    }
    return rec + off;
}

/* 读记录的列值（str 列返回指针，int 列返回值） */
fn db_col(rec: u64, tid: int, col: int) -> u64 {
    let p: u64 = db_col_ptr(rec, tid, col);
    if (db_ttypes[tid][col] == 0) {
        return volatile_load32(p);
    }
    return p;
}

fn db_page_compact(pg: int) {
    let p: u64 = db_page_ptr(pg);
    let nslots: int = volatile_load32(p + 8);
    let fp: int = DB_PAGE_SIZE;
    let tmp: [128]u8;
    let i: int = 0;
    while (i < nslots) {
        let slot: u64 = p + 40 + i * 8;
        let old_off: int = volatile_load32(slot);
        let meta: int = volatile_load32(slot + 4);
        let len: int = db_slot_len(meta);
        let j: int = 0;
        while (j < len) {
            tmp[j] = volatile_load8(p + old_off + j);
            j = j + 1;
        }
        fp = fp - len;
        j = 0;
        while (j < len) {
            volatile_store8(p + fp + j, tmp[j]);
            j = j + 1;
        }
        volatile_store32(slot, fp);
        let rowid: int = db_slot_rowid(meta);
        if (rowid > 0) { db_row_ptr[rowid] = p + fp; }
        i = i + 1;
    }
    volatile_store32(p + 12, fp);
}

fn db_find_row(tid: int, rowid: int) -> u64 {
    if (rowid <= 0 || rowid >= 32768) { return 0; }
    return db_row_ptr[rowid];
}

/* PDB1/PDB2 slot 只有 length（rowid=0）；PDB3 保留已有 rowid 并恢复分配器。 */
fn db_rebuild_rowids() {
    let clear: int = 0;
    while (clear < 32768) {
        db_row_ptr[clear] = 0;
        clear = clear + 1;
    }
    let next: int = 1;
    let tid: int = 0;
    while (tid < db_ntables) {
        let pg: int = db_tfirst[tid];
        while (pg != 0) {
            let p: u64 = db_page_ptr(pg);
            let nslots: int = volatile_load32(p + 8);
            let i: int = 0;
            while (i < nslots) {
                let slot: u64 = p + 40 + i * 8;
                let meta: int = volatile_load32(slot + 4);
                let rowid: int = db_slot_rowid(meta);
                if (rowid == 0) {
                    volatile_store32(slot + 4, db_slot_meta(next, db_slot_len(meta)));
                    db_row_ptr[next] = p + volatile_load32(slot);
                    next = next + 1;
                } else if (rowid >= next) {
                    db_row_ptr[rowid] = p + volatile_load32(slot);
                    next = rowid + 1;
                } else {
                    db_row_ptr[rowid] = p + volatile_load32(slot);
                }
                i = i + 1;
            }
            pg = volatile_load32(p + 16);
        }
        tid = tid + 1;
    }
    db_next_rowid = next;
}

/* 删除当前扫描位置记录，并立即回收 slot 与记录空间。 */
fn db_scan_delete(scan: *DbScan) {
    let p: u64 = db_page_ptr(scan.page);
    let nslots: int = volatile_load32(p + 8);
    let deleted: int = scan.slot - 1;
    let deleted_meta: int = volatile_load32(p + 40 + deleted * 8 + 4);
    let deleted_rowid: int = db_slot_rowid(deleted_meta);
    if (deleted_rowid > 0) { db_row_ptr[deleted_rowid] = 0; }
    let i: int = deleted;
    while (i < nslots - 1) {
        let dst: u64 = p + 40 + i * 8;
        let src: u64 = dst + 8;
        volatile_store32(dst, volatile_load32(src));
        volatile_store32(dst + 4, volatile_load32(src + 4));
        i = i + 1;
    }
    volatile_store32(p + 8, nslots - 1);
    scan.slot = deleted;
    db_page_compact(scan.page);
    db_page_dirty(scan.page);
    db_index_rebuild_table(scan.tid);
}

/* ---- 单列 INT 关系索引：定义持久化，(key,rowid) 内容可重建 ---- */
static DB_INDEX_MAX: int = 8;
static DB_INDEX_ROWS: int = 5376;
static db_nindexes: int = 0;
static db_idx_name: [8][32]u8;
static db_idx_tid: [8]int;
static db_idx_col: [8]int;
static db_idx_count: [8]int;
static db_idx_keys: [8][5376]int;
static db_idx_rowids: [8][5376]int;

fn db_index_name_eq(id: int, name: u64) -> bool {
    let i: int = 0;
    while (i < 32) {
        let a: int = db_idx_name[id][i];
        let b: int = volatile_load8(name + i);
        if (a != b) { return false; }
        if (a == 0) { return true; }
        i = i + 1;
    }
    return true;
}

fn db_index_find_name(name: u64) -> int {
    let i: int = 0;
    while (i < db_nindexes) {
        if (db_index_name_eq(i, name)) { return i; }
        i = i + 1;
    }
    return -1;
}

fn db_index_find(tid: int, col: int) -> int {
    let i: int = 0;
    while (i < db_nindexes) {
        if (db_idx_tid[i] == tid && db_idx_col[i] == col) { return i; }
        i = i + 1;
    }
    return -1;
}

fn db_index_swap(id: int, a: int, b: int) {
    let key: int = db_idx_keys[id][a];
    let rowid: int = db_idx_rowids[id][a];
    db_idx_keys[id][a] = db_idx_keys[id][b];
    db_idx_rowids[id][a] = db_idx_rowids[id][b];
    db_idx_keys[id][b] = key;
    db_idx_rowids[id][b] = rowid;
}

fn db_index_greater(id: int, a: int, b: int) -> bool {
    if (db_idx_keys[id][a] != db_idx_keys[id][b]) {
        return db_idx_keys[id][a] > db_idx_keys[id][b];
    }
    return db_idx_rowids[id][a] > db_idx_rowids[id][b];
}

fn db_index_sift(id: int, root: int, count: int) {
    while (root * 2 + 1 < count) {
        let child: int = root * 2 + 1;
        if (child + 1 < count && db_index_greater(id, child + 1, child)) {
            child = child + 1;
        }
        if (!db_index_greater(id, child, root)) { return; }
        db_index_swap(id, root, child);
        root = child;
    }
}

fn db_index_sort(id: int) {
    let count: int = db_idx_count[id];
    let root: int = count / 2;
    while (root > 0) {
        root = root - 1;
        db_index_sift(id, root, count);
    }
    let end: int = count;
    while (end > 1) {
        end = end - 1;
        db_index_swap(id, 0, end);
        db_index_sift(id, 0, end);
    }
}

fn db_index_rebuild(id: int) -> bool {
    db_idx_count[id] = 0;
    let tid: int = db_idx_tid[id];
    if (tid < 0 || tid >= db_ntables) { return false; }
    let scan: DbScan = db_scan_open(tid);
    let rec: u64 = db_scan_next(&scan);
    while (rec != 0) {
        let n: int = db_idx_count[id];
        if (n >= DB_INDEX_ROWS) { return false; }
        db_idx_keys[id][n] = db_col(rec, tid, db_idx_col[id]) as int;
        db_idx_rowids[id][n] = scan.rowid;
        db_idx_count[id] = n + 1;
        rec = db_scan_next(&scan);
    }
    db_index_sort(id);
    return true;
}

fn db_index_rebuild_table(tid: int) {
    let i: int = 0;
    while (i < db_nindexes) {
        if (db_idx_tid[i] == tid) { db_index_rebuild(i); }
        i = i + 1;
    }
}

fn db_index_rebuild_all() {
    let i: int = 0;
    while (i < db_nindexes) {
        db_index_rebuild(i);
        i = i + 1;
    }
}

fn db_index_create(name: u64, tid: int, col: int) -> int {
    if (db_nindexes >= DB_INDEX_MAX || tid < 0 || tid >= db_ntables
        || col < 0 || col >= db_tcols[tid] || db_ttypes[tid][col] != 0
        || db_index_find_name(name) >= 0 || db_index_find(tid, col) >= 0) {
        return -1;
    }
    let id: int = db_nindexes;
    db_copy_name(ptr_to_int(&db_idx_name[id][0]), name);
    db_idx_tid[id] = tid;
    db_idx_col[id] = col;
    db_idx_count[id] = 0;
    db_nindexes = db_nindexes + 1;
    if (!db_index_rebuild(id)) {
        db_nindexes = db_nindexes - 1;
        return -1;
    }
    return id;
}

fn db_index_on_drop(tid: int, last_tid: int) {
    let i: int = 0;
    while (i < db_nindexes) {
        if (db_idx_tid[i] == tid) {
            let last: int = db_nindexes - 1;
            if (i != last) {
                db_copy_name(ptr_to_int(&db_idx_name[i][0]), ptr_to_int(&db_idx_name[last][0]));
                db_idx_tid[i] = db_idx_tid[last];
                db_idx_col[i] = db_idx_col[last];
                db_idx_count[i] = db_idx_count[last];
                let k: int = 0;
                while (k < db_idx_count[last]) {
                    db_idx_keys[i][k] = db_idx_keys[last][k];
                    db_idx_rowids[i][k] = db_idx_rowids[last][k];
                    k = k + 1;
                }
            }
            db_nindexes = db_nindexes - 1;
        } else {
            i = i + 1;
        }
    }
    if (tid != last_tid) {
        i = 0;
        while (i < db_nindexes) {
            if (db_idx_tid[i] == last_tid) { db_idx_tid[i] = tid; }
            i = i + 1;
        }
    }
}

fn db_index_lower_bound(id: int, key: int, inclusive: bool) -> int {
    let lo: int = 0;
    let hi: int = db_idx_count[id];
    while (lo < hi) {
        let mid: int = (lo + hi) / 2;
        if (db_idx_keys[id][mid] < key || (!inclusive && db_idx_keys[id][mid] == key)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

struct DbIndexScan {
    id: int,
    pos: int,
    key: int,
    op: int, /* 0 eq, 1 ne, 2 lt, 3 gt, 4 le, 5 ge */
}

fn db_index_scan_open(id: int, key: int, op: int) -> DbIndexScan {
    let pos: int = 0;
    if (op == 0 || op == 5) { pos = db_index_lower_bound(id, key, true); }
    if (op == 3) { pos = db_index_lower_bound(id, key, false); }
    return DbIndexScan { id: id, pos: pos, key: key, op: op };
}

fn db_index_scan_next(scan: *DbIndexScan) -> u64 {
    while (scan.pos < db_idx_count[scan.id]) {
        let pos: int = scan.pos;
        let key: int = db_idx_keys[scan.id][pos];
        scan.pos = scan.pos + 1;
        if (scan.op == 0 && key > scan.key) { return 0; }
        if ((scan.op == 2 && key >= scan.key) || (scan.op == 4 && key > scan.key)) { return 0; }
        let matched: bool = scan.op == 1 || scan.op == 2 || scan.op == 3 || scan.op == 4 || scan.op == 5;
        if (scan.op == 0 && key == scan.key) { matched = true; }
        if (scan.op == 1 && key == scan.key) { matched = false; }
        if (matched) {
            let row: u64 = db_find_row(db_idx_tid[scan.id], db_idx_rowids[scan.id][pos]);
            if (row != 0) { return row; }
        }
    }
    return 0;
}

/* 列名构造辅助：把表目录 dump 成 schema 文本（供 db ask/输出）——返回长度 */
fn db_schema(tid: int, buf: u64) -> int {
    let o: int = 0;
    let i: int = 0;
    while (i < db_tcols[tid]) {
        if (i > 0) {
            volatile_store8(buf + o, 44);
            o = o + 1;
        }
        let name_i: int = 0;
        while (volatile_load8(db_tcol[tid][i] + name_i) != 0) {
            volatile_store8(buf + o, volatile_load8(db_tcol[tid][i] + name_i));
            o = o + 1;
            name_i = name_i + 1;
        }
        volatile_store8(buf + o, 58); /* : */
        o = o + 1;
        if (db_ttypes[tid][i] == 0) {
            let s: str = "int";
            let k: int = 0;
            while (s[k] != 0) {
                volatile_store8(buf + o, s[k]);
                o = o + 1;
                k = k + 1;
            }
        } else {
            let s2: str = "str";
            let k2: int = 0;
            while (s2[k2] != 0) {
                volatile_store8(buf + o, s2[k2]);
                o = o + 1;
                k2 = k2 + 1;
            }
        }
        i = i + 1;
    }
    volatile_store8(buf + o, 0);
    return o;
}
