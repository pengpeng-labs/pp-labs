/* db_kv.pp：KV 存储（LevelDB API 风格）——有序数组 + 二分查找
   v1：≤64 键值对；key ≤31B；value ≤63B（槽末字节保留为 NUL）
   （当前规模下使用固定容量有序数组，不引入 LSM/SkipList） */

static kv_keys: [64][32]u8;
static kv_vals: [64][64]u8;
static kv_count: int = 0;

/* 比较 key 与 kv_keys[i]：返回 0 相等 / 1 key 大 / -1 key 小 */
fn kv_cmp(key: u64, i: int) -> int {
    let k: int = 0;
    while (k < 31) {
        let a: int = volatile_load8(key + k);
        let b: int = kv_keys[i][k];
        if (a != b) {
            if (a > b) {
                return 1;
            }
            return -1;
        }
        if (a == 0) {
            return 0;
        }
        k = k + 1;
    }
    return 0; /* 超长 key 按前 31B 截断比较 */
}

fn kv_copy_cstr(dst: u64, src: u64, cap: int) {
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

/* 二分查找 key：返回槽位（找到或插入点） */
fn kv_find(key: u64) -> int {
    let lo: int = 0;
    let hi: int = kv_count - 1;
    while (lo <= hi) {
        let mid: int = (lo + hi) / 2;
        let c: int = kv_cmp(key, mid);
        if (c == 0) {
            return mid;
        }
        if (c > 0) {
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return lo;   /* 插入点 */
}

/* 插入（保持有序）：key/value 指针，返回 1 成功 */
fn kv_put(key: u64, value: u64) -> int {
    let idx: int = kv_find(key);
    if (idx < kv_count && kv_cmp(key, idx) == 0) {
        /* 已存在：更新 */
        kv_copy_cstr(ptr_to_int(&kv_vals[idx][0]), value, 64);
        return 1;
    }
    if (kv_count >= 64) {
        return 0;   /* 满 */
    }
    /* 后移腾位 */
    let i: int = kv_count;
    while (i > idx) {
        let j: int = 0;
        while (j < 32) {
            kv_keys[i][j] = kv_keys[i - 1][j];
            j = j + 1;
        }
        let k: int = 0;
        while (k < 64) {
            kv_vals[i][k] = kv_vals[i - 1][k];
            k = k + 1;
        }
        i = i - 1;
    }
    /* 写入 */
    kv_copy_cstr(ptr_to_int(&kv_keys[idx][0]), key, 32);
    kv_copy_cstr(ptr_to_int(&kv_vals[idx][0]), value, 64);
    kv_count = kv_count + 1;
    return 1;
}

/* 读取：value 拷贝到 buf，返回长度；未找到返回 -1 */
fn kv_get(key: u64, buf: u64) -> int {
    let idx: int = kv_find(key);
    if (idx >= kv_count || kv_cmp(key, idx) != 0) {
        return -1;
    }
    let len: int = 0;
    let j: int = 0;
    while (j < 63 && kv_vals[idx][j] != 0) {
        volatile_store8(buf + j, kv_vals[idx][j]);
        len = len + 1;
        j = j + 1;
    }
    volatile_store8(buf + len, 0);
    return len;
}

/* 删除：返回 1 成功 */
fn kv_del(key: u64) -> int {
    let idx: int = kv_find(key);
    if (idx >= kv_count || kv_cmp(key, idx) != 0) {
        return 0;
    }
    let i: int = idx;
    while (i < kv_count - 1) {
        let j: int = 0;
        while (j < 32) {
            kv_keys[i][j] = kv_keys[i + 1][j];
            j = j + 1;
        }
        let k: int = 0;
        while (k < 64) {
            kv_vals[i][k] = kv_vals[i + 1][k];
            k = k + 1;
        }
        i = i + 1;
    }
    kv_count = kv_count - 1;
    return 1;
}
