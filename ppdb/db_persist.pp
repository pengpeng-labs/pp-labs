/* db_persist.pp：二进制 db save/load——整库（表目录 + KV + Doc + 页区）序列化到 FS 文件
   镜像格式（magic 0x34424450 = "PDB4"；load 兼容 PDB1/PDB2/PDB3）：
     [0] u32 magic
     [4] u32 表数
     [8] u32 空闲页数 nfree
     [12] u32 空闲页号[nfree]
     表目录 × n：名字[32] + 列名[4][32] + u32 列数 + u32 类型[4] + u32 首页 + u32 尾页（188B/表）
     KV：u32 条数 + 条数 × (key[32] + val[64])
     Doc：u32 文档数 + 条数 × (name[32] + cont[128])
     Index：u32 定义数 + 条数 × (name[32] + table_id u32 + col u32)
     页区：u32 页数 npages + npages × 512B */

static db_img: [12000]u8;   /* 头部/目录/KV/Doc 拼装缓冲 */
static db_img_off: int = 0;

fn img_u32(v: int) {
    volatile_store32(ptr_to_int(&db_img[0]) + db_img_off, v);
    db_img_off = db_img_off + 4;
}

fn img_copy(src: u64, n: int) {
    let j: int = 0;
    while (j < n) {
        volatile_store8(ptr_to_int(&db_img[0]) + db_img_off + j, volatile_load8(src + j));
        j = j + 1;
    }
    db_img_off = db_img_off + n;
}

fn rd_u32(buf: u64) -> int {
    return volatile_load32(buf);
}

/* 第一遍只验证，不修改数据库；通过后 db_load 才提交全局状态。 */
fn db_validate_image(idx: int) -> bool {
    let img: u64 = ptr_to_int(&db_img[0]);
    if (hf_read_at(idx, img, 12, 0) != 12) {
        return false;
    }
    let magic: int = rd_u32(img);
    if (magic != 0x31424450 && magic != 0x32424450 && magic != 0x33424450
        && magic != 0x34424450) {
        return false;
    }
    let ntables: int = rd_u32(img + 4);
    let nfree: int = rd_u32(img + 8);
    if (ntables < 0 || ntables > 8 || nfree < 0 || nfree > DB_NPAGES) {
        return false;
    }
    let o: int = 12;
    let max_page_ref: int = 0;
    let table_cols: [8]int;
    let table_types: [8][4]int;
    if (nfree > 0) {
        if (hf_read_at(idx, img, nfree * 4, o) != nfree * 4) {
            return false;
        }
        let f: int = 0;
        while (f < nfree) {
            let pg: int = rd_u32(img + f * 4);
            if (pg < 1 || pg > DB_NPAGES) {
                return false;
            }
            if (pg > max_page_ref) {
                max_page_ref = pg;
            }
            f = f + 1;
        }
    }
    o = o + nfree * 4;
    let table_size: int = 60;
    let meta: int = 32;
    if (magic == 0x32424450 || magic == 0x33424450 || magic == 0x34424450) {
        table_size = 188;
        meta = 160;
    }
    let t: int = 0;
    while (t < ntables) {
        if (hf_read_at(idx, img, table_size, o) != table_size) {
            return false;
        }
        let ncols: int = rd_u32(img + meta);
        if (ncols < 1 || ncols > 4) {
            return false;
        }
        table_cols[t] = ncols;
        let c: int = 0;
        while (c < ncols) {
            let ty: int = rd_u32(img + meta + 4 + c * 4);
            if (ty != 0 && ty != 1) {
                return false;
            }
            table_types[t][c] = ty;
            c = c + 1;
        }
        let first: int = rd_u32(img + meta + 20);
        let last: int = rd_u32(img + meta + 24);
        if (first < 1 || first > DB_NPAGES || last < 1 || last > DB_NPAGES) {
            return false;
        }
        if (first > max_page_ref) { max_page_ref = first; }
        if (last > max_page_ref) { max_page_ref = last; }
        o = o + table_size;
        t = t + 1;
    }
    if (hf_read_at(idx, img, 4, o) != 4) {
        return false;
    }
    let nkv: int = rd_u32(img);
    if (nkv < 0 || nkv > 64) {
        return false;
    }
    o = o + 4 + nkv * 96;
    if (hf_read_at(idx, img, 4, o) != 4) {
        return false;
    }
    let ndoc: int = rd_u32(img);
    if (ndoc < 0 || ndoc > 16) {
        return false;
    }
    o = o + 4 + ndoc * 160;
    if (magic == 0x34424450) {
        if (hf_read_at(idx, img, 4, o) != 4) { return false; }
        let nindexes: int = rd_u32(img);
        if (nindexes < 0 || nindexes > DB_INDEX_MAX) { return false; }
        o = o + 4;
        let ix: int = 0;
        while (ix < nindexes) {
            if (hf_read_at(idx, img, 40, o) != 40) { return false; }
            let itid: int = rd_u32(img + 32);
            let icol: int = rd_u32(img + 36);
            if (itid < 0 || itid >= ntables || icol < 0 || icol >= table_cols[itid]
                || table_types[itid][icol] != 0) {
                return false;
            }
            o = o + 40;
            ix = ix + 1;
        }
    }
    if (hf_read_at(idx, img, 4, o) != 4) {
        return false;
    }
    let npages: int = rd_u32(img);
    if (npages < 0 || npages > DB_NPAGES) {
        return false;
    }
    if (max_page_ref > npages) {
        return false;
    }
    if (npages > 0 && hf_read_at(idx, img, 1, o + 4 + npages * DB_PAGE_SIZE - 1) != 1) {
        return false;
    }
    return true;
}

/* 保存整库到文件 name（文件抽象 hf_*，双宿主）；打印结果 */
fn db_save(name: u64) {
    if (db_tx_active) {
        serial_print("save: transaction active\n");
        return;
    }
    let idx: int = hf_find(int_to_ptr(name));
    if (idx < 0) {
        idx = hf_create(int_to_ptr(name));
    }
    if (idx < 0) {
        serial_print("save: fs full\n");
        return;
    }
    db_img_off = 0;
    img_u32(0x34424450);
    img_u32(db_ntables);
    img_u32(db_free_n);
    let f: int = 0;
    while (f < db_free_n) {
        img_u32(db_free_list[f]);
        f = f + 1;
    }
    let t: int = 0;
    while (t < db_ntables) {
        img_copy(db_tname[t], 32);
        let cn: int = 0;
        while (cn < 4) {
            img_copy(db_tcol[t][cn], 32);
            cn = cn + 1;
        }
        img_u32(db_tcols[t]);
        let c: int = 0;
        while (c < 4) {
            img_u32(db_ttypes[t][c]);
            c = c + 1;
        }
        img_u32(db_tfirst[t]);
        img_u32(db_tlast[t]);
        t = t + 1;
    }
    img_u32(kv_count);
    let i: int = 0;
    while (i < kv_count) {
        img_copy(ptr_to_int(&kv_keys[i][0]), 32);
        img_copy(ptr_to_int(&kv_vals[i][0]), 64);
        i = i + 1;
    }
    img_u32(doc_count);
    let d: int = 0;
    while (d < doc_count) {
        img_copy(ptr_to_int(&doc_names[d][0]), 32);
        img_copy(ptr_to_int(&doc_cont[d][0]), 128);
        d = d + 1;
    }
    img_u32(db_nindexes);
    let ix: int = 0;
    while (ix < db_nindexes) {
        img_copy(ptr_to_int(&db_idx_name[ix][0]), 32);
        img_u32(db_idx_tid[ix]);
        img_u32(db_idx_col[ix]);
        ix = ix + 1;
    }
    let head: int = db_img_off;
    hf_write(idx, ptr_to_int(&db_img[0]), head);
    /* 页区：写页数 + 全部已分配页 */
    img_u32(db_next_page);
    hf_write_at(idx, ptr_to_int(&db_img[0]) + head, 4, head);
    hf_write_at(idx, db_page_ptr(1), db_next_page * DB_PAGE_SIZE, head + 4);
    serial_print("db saved (");
    print_int(head + 4 + db_next_page * DB_PAGE_SIZE);
    serial_print(" bytes)\n");
    hf_close(idx);
}

/* 从文件恢复整库（文件抽象 hf_*，双宿主）；打印结果 */
fn db_load(name: u64) {
    if (db_tx_active) {
        serial_print("load: transaction active\n");
        return;
    }
    let idx: int = hf_find(int_to_ptr(name));
    if (idx < 0) {
        serial_print("load: no such file\n");
        return;
    }
    if (!db_validate_image(idx)) {
        serial_print("load: invalid or truncated image\n");
        hf_close(idx);
        return;
    }
    let img: u64 = ptr_to_int(&db_img[0]);
    hf_read_at(idx, img, 16, 0);
    let magic: int = rd_u32(img);
    if (magic != 0x31424450 && magic != 0x32424450 && magic != 0x33424450
        && magic != 0x34424450) {
        serial_print("load: bad magic\n");
        hf_close(idx);
        return;
    }
    let ntables: int = rd_u32(img + 4);
    let nfree: int = rd_u32(img + 8);
    if (ntables > 8 || nfree > 128) {
        serial_print("load: bad header\n");
        hf_close(idx);
        return;
    }
    db_ntables = ntables;
    db_free_n = nfree;
    hf_read_at(idx, ptr_to_int(&db_free_list[0]), nfree * 4, 12);
    let o: int = 12 + nfree * 4;
    /* 目录 */
    let t: int = 0;
    while (t < ntables) {
        let table_size: int = 60;
        if (magic == 0x32424450 || magic == 0x33424450 || magic == 0x34424450) {
            table_size = 188;
        }
        hf_read_at(idx, img, table_size, o);
        let b: int = 0;
        while (b < 32) {
            db_tname_buf[t][b] = volatile_load8(img + b);
            b = b + 1;
        }
        db_tname[t] = ptr_to_int(&db_tname_buf[t][0]);
        db_set_default_col_names(t);
        let meta: int = 32;
        if (magic == 0x32424450 || magic == 0x33424450 || magic == 0x34424450) {
            let cn: int = 0;
            while (cn < 4) {
                db_copy_name(db_tcol[t][cn], img + 32 + cn * 32);
                cn = cn + 1;
            }
            meta = 160;
        }
        db_tcols[t] = rd_u32(img + meta);
        let c: int = 0;
        while (c < 4) {
            db_ttypes[t][c] = rd_u32(img + meta + 4 + c * 4);
            c = c + 1;
        }
        db_tfirst[t] = rd_u32(img + meta + 20);
        db_tlast[t] = rd_u32(img + meta + 24);
        o = o + table_size;
        t = t + 1;
    }
    /* KV */
    hf_read_at(idx, img, 4, o);
    kv_count = rd_u32(img);
    o = o + 4;
    let i: int = 0;
    while (i < kv_count) {
        hf_read_at(idx, ptr_to_int(&kv_keys[i][0]), 32, o);
        hf_read_at(idx, ptr_to_int(&kv_vals[i][0]), 64, o + 32);
        o = o + 96;
        i = i + 1;
    }
    /* Doc */
    hf_read_at(idx, img, 4, o);
    doc_count = rd_u32(img);
    o = o + 4;
    let d: int = 0;
    while (d < doc_count) {
        hf_read_at(idx, ptr_to_int(&doc_names[d][0]), 32, o);
        hf_read_at(idx, ptr_to_int(&doc_cont[d][0]), 128, o + 32);
        o = o + 160;
        d = d + 1;
    }
    db_nindexes = 0;
    if (magic == 0x34424450) {
        hf_read_at(idx, img, 4, o);
        db_nindexes = rd_u32(img);
        o = o + 4;
        let ix: int = 0;
        while (ix < db_nindexes) {
            hf_read_at(idx, img, 40, o);
            db_copy_name(ptr_to_int(&db_idx_name[ix][0]), img);
            db_idx_tid[ix] = rd_u32(img + 32);
            db_idx_col[ix] = rd_u32(img + 36);
            db_idx_count[ix] = 0;
            o = o + 40;
            ix = ix + 1;
        }
    }
    /* 页区 */
    hf_read_at(idx, img, 4, o);
    let npages: int = rd_u32(img);
    db_next_page = npages;
    o = o + 4;
    hf_read_at(idx, db_page_ptr(1), npages * DB_PAGE_SIZE, o);
    db_rebuild_rowids();
    db_index_rebuild_all();
    serial_print("db loaded (");
    print_int(ntables);
    serial_print(" tables)\n");
    hf_close(idx);
}
