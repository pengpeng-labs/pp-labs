import "../db_core.pp";
import "../db_kv.pp";
import "../db_doc.pp";
import "../host_native.pp";

fn fail(code: int) -> int {
    return code;
}

fn main() -> int {
    /* 128 个逻辑页必须完整映射到 64 KiB 页区。 */
    let i: int = 1;
    while (i <= DB_NPAGES) {
        if (db_page_alloc() != i) {
            return fail(1);
        }
        i = i + 1;
    }
    if (db_page_alloc() != -1) {
        return fail(2);
    }
    if (db_page_ptr(128) - db_page_ptr(1) != 127 * DB_PAGE_SIZE) {
        return fail(3);
    }
    volatile_store8(db_page_ptr(1), 17);
    volatile_store8(db_page_ptr(128) + DB_PAGE_SIZE - 1, 29);
    if (db_pages[0] != 17 || db_pages[65535] != 29) {
        return fail(4);
    }

    /* KV 槽保留末字节为 NUL，短值更新必须清掉旧尾部。 */
    let key: [40]u8;
    let value: [80]u8;
    i = 0;
    while (i < 39) {
        key[i] = 97;
        i = i + 1;
    }
    key[39] = 0;
    i = 0;
    while (i < 79) {
        value[i] = 98;
        i = i + 1;
    }
    value[79] = 0;
    if (kv_put(ptr_to_int(&key[0]), ptr_to_int(&value[0])) != 1) {
        return fail(5);
    }
    let out: [64]u8;
    if (kv_get(ptr_to_int(&key[0]), ptr_to_int(&out[0])) != 63 || out[63] != 0) {
        return fail(6);
    }
    let short_value: [2]u8;
    short_value[0] = 120;
    short_value[1] = 0;
    kv_put(ptr_to_int(&key[0]), ptr_to_int(&short_value[0]));
    if (kv_get(ptr_to_int(&key[0]), ptr_to_int(&out[0])) != 1 || out[1] != 0) {
        return fail(7);
    }

    /* Doc 使用相同的固定槽契约。 */
    let doc_name: [40]u8;
    let content: [140]u8;
    i = 0;
    while (i < 39) {
        doc_name[i] = 110;
        i = i + 1;
    }
    doc_name[39] = 0;
    i = 0;
    while (i < 139) {
        content[i] = 99;
        i = i + 1;
    }
    content[139] = 0;
    if (doc_put(ptr_to_int(&doc_name[0]), ptr_to_int(&content[0])) != 1) {
        return fail(8);
    }
    let doc_out: [128]u8;
    if (doc_get(ptr_to_int(&doc_name[0]), ptr_to_int(&doc_out[0])) != 127 || doc_out[127] != 0) {
        return fail(9);
    }
    return 0;
}
