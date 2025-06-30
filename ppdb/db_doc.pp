/* db_doc.pp：Doc 存储（JSON 文档按名存取）
   v1：≤16 文档；name ≤32B；content ≤128B；复用 json.pp 能力（调用方校验） */

static doc_names: [[u8; 32]; 16];
static doc_cont: [[u8; 128]; 16];
static doc_count: int = 0;

/* 按名查找文档，返回索引；未找到 -1 */
fn doc_find(name: u64) -> int {
    let i: int = 0;
    while (i < doc_count) {
        let j: int = 0;
        let eq: int = 1;
        while (j < 32) {
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

/* 存文档：返回 1 成功 */
fn doc_put(name: u64, content: u64) -> int {
    let idx: int = doc_find(name);
    if (idx < 0) {
        if (doc_count >= 16) {
            return 0;
        }
        idx = doc_count;
        let j: int = 0;
        while (j < 32) {
            doc_names[idx][j] = volatile_load8(name + j);
            if (volatile_load8(name + j) == 0) {
                break;
            }
            j = j + 1;
        }
        doc_count = doc_count + 1;
    }
    let k: int = 0;
    while (k < 128) {
        doc_cont[idx][k] = volatile_load8(content + k);
        if (volatile_load8(content + k) == 0) {
            break;
        }
        k = k + 1;
    }
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
    while (j < 128 && doc_cont[idx][j] != 0) {
        volatile_store8(buf + j, doc_cont[idx][j]);
        len = len + 1;
        j = j + 1;
    }
    volatile_store8(buf + len, 0);
    return len;
}
