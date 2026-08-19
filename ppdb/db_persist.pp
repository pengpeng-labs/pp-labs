/* db_persist.pp：二进制 db save/load——整库（表目录 + KV + Doc + 页区）序列化到 FS 文件
   镜像格式（magic 0x31424450 = "PDB1"）：
     [0] u32 magic
     [4] u32 表数
     [8] u32 空闲页数 nfree
     [12] u32 空闲页号[nfree]
     表目录 × n：名字[32] + u32 列数 + u32 类型[4] + u32 首页 + u32 尾页（60B/表）
     KV：u32 条数 + 条数 × (key[32] + val[64])
     Doc：u32 文档数 + 条数 × (name[32] + cont[128])
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

/* 保存整库到文件 name（文件抽象 hf_*，双宿主）；打印结果 */
fn db_save(name: u64) {
    let idx: int = hf_find(int_to_ptr(name));
    if (idx < 0) {
        idx = hf_create(int_to_ptr(name));
    }
    if (idx < 0) {
        serial_print("save: fs full\n");
        return;
    }
    db_img_off = 0;
    img_u32(0x31424450);
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
    let head: int = db_img_off;
    hf_write(idx, ptr_to_int(&db_img[0]), head);
    /* 页区：写页数 + 全部已分配页 */
    img_u32(db_next_page);
    hf_write_at(idx, ptr_to_int(&db_img[0]) + head, 4, head);
    hf_write_at(idx, db_page_ptr(1), db_next_page * DB_PAGE_SIZE, head + 4);
    serial_print("db saved (");
    print_int(head + 4 + db_next_page * DB_PAGE_SIZE);
    serial_print(" bytes)\n");
}

/* 从文件恢复整库（文件抽象 hf_*，双宿主）；打印结果 */
fn db_load(name: u64) {
    let idx: int = hf_find(int_to_ptr(name));
    if (idx < 0) {
        serial_print("load: no such file\n");
        return;
    }
    let img: u64 = ptr_to_int(&db_img[0]);
    hf_read_at(idx, img, 16, 0);
    if (rd_u32(img) != 0x31424450) {
        serial_print("load: bad magic\n");
        return;
    }
    let ntables: int = rd_u32(img + 4);
    let nfree: int = rd_u32(img + 8);
    if (ntables > 8 || nfree > 128) {
        serial_print("load: bad header\n");
        return;
    }
    db_ntables = ntables;
    db_free_n = nfree;
    hf_read_at(idx, ptr_to_int(&db_free_list[0]), nfree * 4, 12);
    let o: int = 12 + nfree * 4;
    /* 目录 */
    let t: int = 0;
    while (t < ntables) {
        hf_read_at(idx, img, 60, o);
        let b: int = 0;
        while (b < 32) {
            db_tname_buf[t][b] = volatile_load8(img + b);
            b = b + 1;
        }
        db_tname[t] = ptr_to_int(&db_tname_buf[t][0]);
        db_tcols[t] = rd_u32(img + 32);
        let c: int = 0;
        while (c < 4) {
            db_ttypes[t][c] = rd_u32(img + 36 + c * 4);
            c = c + 1;
        }
        db_tfirst[t] = rd_u32(img + 52);
        db_tlast[t] = rd_u32(img + 56);
        o = o + 60;
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
    /* 页区 */
    hf_read_at(idx, img, 4, o);
    let npages: int = rd_u32(img);
    db_next_page = npages;
    o = o + 4;
    hf_read_at(idx, db_page_ptr(1), npages * DB_PAGE_SIZE, o);
    serial_print("db loaded (");
    print_int(ntables);
    serial_print(" tables)\n");
}
