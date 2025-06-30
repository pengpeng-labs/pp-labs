/* db_core.pp：pp-db 存储内核——页式堆表（页链 + slot array）+ 记录管理（宿主无关）
   页提供者接口由宿主实现（host_ppos.pp / host_native.pp）：
     fn db_page_alloc() -> int;      分配页，返回页号（-1 表示满）
     fn db_page_ptr(n: int) -> u64;  页 n 的内存指针（地址通道 64 位，宿主高地址可用）
     fn db_page_dirty(n: int);       标记页脏（宿主机写回用） */

static DB_PAGE_SIZE: int = 512;
static DB_NPAGES: int = 128;

/* ---- 表目录（≤8 表，每表 ≤4 列）---- */
static db_ntables: int = 0;
static db_tname_buf: [[u8; 32]; 8];   /* 表名稳定存储（目录存指针，指向这里） */
static db_tname: [u64; 8];
static db_tcols: [int; 8];
static db_ttypes: [[int; 4]; 8];   /* 0=int(4B) 1=str(32B) */
static db_tfirst: [int; 8];      /* 首页号 */
static db_tlast: [int; 8];       /* 尾页号 */

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
    if (db_ntables >= 8 || ncols < 1 || ncols > 4) {
        return -1;
    }
    let tid: int = db_ntables;
    /* 表名拷入稳定存储（目录只存指针，避免指向命令缓冲） */
    let j: int = 0;
    while (j < 32) {
        db_tname_buf[tid][j] = name[j];
        if (name[j] == 0) {
            break;
        }
        j = j + 1;
    }
    db_tname[tid] = ptr_to_int(&db_tname_buf[tid][0]);
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
    let i: int = 0;
    while (i < db_ntables) {
        let j: int = 0;
        let eq: int = 1;
        while (j < 32) {
            let a: int = volatile_load8(db_tname[i] + j);
            let b: int = name[j];
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

/* 删表：释放全部页 + 目录压缩（最后一个表移入空位）；返回 1 成功 */
fn db_drop_table(tid: int) -> int {
    if (tid < 0 || tid >= db_ntables) {
        return 0;
    }
    let pg: int = db_tfirst[tid];
    while (pg != 0) {
        let p: u64 = db_page_ptr(pg);
        let npg: int = volatile_load32(p + 16);
        db_page_free(pg);   /* 宿主实现：释放页进空闲链 */
        pg = npg;
    }
    let last: int = db_ntables - 1;
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
            c = c + 1;
        }
        db_tfirst[tid] = db_tfirst[last];
        db_tlast[tid] = db_tlast[last];
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

/* 插入一行：vals 指向值数组（[u64;4]：每列一个 8 字节槽；str 列存指针）；返回 1 成功 */
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
    volatile_store32(slot + 4, rsize);
    volatile_store32(p + 8, nslots + 1);
    volatile_store32(p + 12, rec_off);
    db_page_dirty(pg);
    return 1;
}

/* ---- 扫描迭代器 ---- */
static db_scan_tid: int = 0;
static db_scan_page: int = 0;
static db_scan_slot: int = 0;

fn db_scan_init(tid: int) {
    db_scan_tid = tid;
    db_scan_page = db_tfirst[tid];
    db_scan_slot = 0;
}

/* 返回下一条记录数据指针（记录从字段 0 起）；无则 0 */
fn db_scan_next() -> u64 {
    while (db_scan_page != 0) {
        let p: u64 = db_page_ptr(db_scan_page);
        let nslots: int = volatile_load32(p + 8);
        while (db_scan_slot < nslots) {
            let slot: u64 = p + 40 + db_scan_slot * 8;
            let off: int = volatile_load32(slot);
            db_scan_slot = db_scan_slot + 1;
            if (off != 0) {
                return p + off;
            }
        }
        db_scan_page = volatile_load32(p + 16);
        db_scan_slot = 0;
    }
    return 0;
}

/* 读记录的列值（str 列返回指针，int 列返回值） */
fn db_col(rec: u64, tid: int, col: int) -> u64 {
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
    if (db_ttypes[tid][col] == 0) {
        return volatile_load32(rec + off);
    }
    return rec + off;
}

/* 删除当前扫描位置记录（标记 slot 为空） */
fn db_scan_delete() {
    let p: u64 = db_page_ptr(db_scan_page);
    let slot: u64 = p + 40 + (db_scan_slot - 1) * 8;
    volatile_store32(slot, 0);
    db_page_dirty(db_scan_page);
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
