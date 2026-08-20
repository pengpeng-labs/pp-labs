/* db_doc.pp：Doc 存储（JSON 文档按名存取）
   v1：≤16 文档；name ≤31B；content ≤127B（槽末字节保留为 NUL） */

static doc_names: [16][32]u8;
static doc_cont: [16][128]u8;
static doc_count: int = 0;

/* 按名查找文档，返回索引；未找到 -1 */
fn doc_find(name: u64) -> int {
    let i: int = 0;
    while (i < doc_count) {
        let j: int = 0;
        let eq: int = 1;
        while (j < 31) {
            let a: int = volatile_load8(name + j);
            let b: int = doc_names[i][j];
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

fn doc_copy_cstr(dst: u64, src: u64, cap: int) {
    let i: int = 0;
    while (i < cap) {
        volatile_store8(dst + i, 0);
        i = i + 1;
    }
    i = 0;
    while (i < cap - 1 && volatile_load8(src + i) != 0) {
        volatile_store8(dst + i, volatile_load8(src + i));
        i = i + 1;
    }
}

/* 存文档：返回 1 成功 */
fn doc_put(name: u64, content: u64) -> int {
    let idx: int = doc_find(name);
    if (idx < 0) {
        if (doc_count >= 16) {
            return 0;
        }
        idx = doc_count;
        doc_copy_cstr(ptr_to_int(&doc_names[idx][0]), name, 32);
        doc_count = doc_count + 1;
    }
    doc_copy_cstr(ptr_to_int(&doc_cont[idx][0]), content, 128);
    return 1;
}

/* 取文档：内容拷到 buf，返回长度；未找到 -1 */
fn doc_get(name: u64, buf: u64) -> int {
    let idx: int = doc_find(name);
    if (idx < 0) {
        return -1;
    }
    let len: int = 0;
    let j: int = 0;
    while (j < 127 && doc_cont[idx][j] != 0) {
        volatile_store8(buf + j, doc_cont[idx][j]);
        len = len + 1;
        j = j + 1;
    }
    volatile_store8(buf + len, 0);
    return len;
}
