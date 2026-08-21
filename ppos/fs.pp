/* 内存文件系统：16 个文件，名 ≤32 字节；内容存共享 128KB 缓冲池（可变大小，总容量 131072B） */

static fs_pool: [131072]u8;
static fs_off: [16]int;      /* 文件内容在池中的偏移 */
static fs_name: [16][32]u8;
static fs_size: [16]int;
static fs_used: [16]int;
static fs_bump: int = 0;       /* 池分配游标（文件不收缩） */

fn fs_init() {
    let i: int = 0;
    while (i < 16) {
        fs_used[i] = 0;
        i = i + 1;
    }
    fs_bump = 0;
    /* 出厂默认配置：DeepSeek API key（可用 write key <key> 覆盖） */
    let k: str = "sk-7777ed9e1e59443ab124f3852aa54745";
    let ki: int = fs_create("key");
    if (ki >= 0) {
        fs_write(ki, k);
    }
    /* 测试脚本 */
    let s: str = "# demo script\necho hello from script\nls\napp list\n";
    let si: int = fs_create("demo.sh");
    if (si >= 0) {
        fs_write(si, s);
    }
}

/* 比较第 idx 个文件名与 str */
fn fs_name_eq(idx: int, s: str) -> int {
    let j: int = 0;
    while (j < 32) {
        if (fs_name[idx][j] != s[j]) {
            return 0;
        }
        if (fs_name[idx][j] == 0) {
            return 1;
        }
        j = j + 1;
    }
    return 1;
}

fn fs_find(name: str) -> int {
    let i: int = 0;
    while (i < 16) {
        if (fs_used[i] == 1) {
            if (fs_name_eq(i, name) == 1) {
                return i;
            }
        }
        i = i + 1;
    }
    return -1;
}

fn fs_create(name: str) -> int {
    if (fs_find(name) >= 0) {
        return -1;
    }
    let i: int = 0;
    while (i < 16) {
        if (fs_used[i] == 0) {
            if (fs_bump >= 131072) {
                return -1;   /* 池满 */
            }
            let j: int = 0;
            while (j < 32) {
                fs_name[i][j] = name[j];
                if (name[j] == 0) {
                    j = 32;
                } else {
                    j = j + 1;
                }
            }
            fs_off[i] = fs_bump;
            fs_size[i] = 0;
            fs_used[i] = 1;
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn fs_write(idx: int, data: str) {
    let j: int = 0;
    while (j < 256) {
        if (fs_off[idx] + j >= 131072) {
            fs_size[idx] = j;
            return;
        }
        fs_pool[fs_off[idx] + j] = data[j];
        if (data[j] == 0) {
            fs_size[idx] = j;
            if (fs_off[idx] + j > fs_bump) {
                fs_bump = fs_off[idx] + j;
            }
            return;
        }
        j = j + 1;
    }
    fs_size[idx] = 256;
    if (fs_off[idx] + 256 > fs_bump) {
        fs_bump = fs_off[idx] + 256;
    }
}

/* 二进制写入（显式长度，不受 0 字节截断） */
fn fs_write_bin(idx: int, data: int, len: int) {
    let j: int = 0;
    while (j < len && fs_off[idx] + j < 131072) {
        fs_pool[fs_off[idx] + j] = volatile_load8(data + j);
        j = j + 1;
    }
    fs_size[idx] = j;
    if (fs_off[idx] + j > fs_bump) {
        fs_bump = fs_off[idx] + j;
    }
}

/* 二进制写入（offset 偏移处，供拼接/分块写） */
fn fs_write_bin_at(idx: int, data: int, len: int, off: int) {
    let j: int = 0;
    while (j < len && fs_off[idx] + off + j < 131072) {
        fs_pool[fs_off[idx] + off + j] = volatile_load8(data + j);
        j = j + 1;
    }
    if (off + j > fs_size[idx]) {
        fs_size[idx] = off + j;
    }
    if (fs_off[idx] + off + j > fs_bump) {
        fs_bump = fs_off[idx] + off + j;
    }
}

fn fs_print(idx: int) {
    let j: int = 0;
    while (j < fs_size[idx]) {
        console_putc(fs_pool[fs_off[idx] + j]);
        j = j + 1;
    }
    console_putc(10);
}

/* 拷贝文件内容到 buf，返回长度 */
fn fs_read(idx: int, buf: int) -> int {
    let j: int = 0;
    while (j < fs_size[idx]) {
        volatile_store8(buf + j, fs_pool[fs_off[idx] + j]);
        j = j + 1;
    }
    return j;
}

/* 读取文件指定区间（off 起，len 字节；越界截断），返回实际字节数 */
fn fs_read_at(idx: int, buf: int, len: int, off: int) -> int {
    let j: int = 0;
    while (j < len && off + j < fs_size[idx]) {
        volatile_store8(buf + j, fs_pool[fs_off[idx] + off + j]);
        j = j + 1;
    }
    return j;
}

fn fs_list() {
    let i: int = 0;
    while (i < 16) {
        if (fs_used[i] == 1) {
            let j: int = 0;
            while (fs_name[i][j] != 0) {
                console_putc(fs_name[i][j]);
                j = j + 1;
            }
            console_putc(32);
        }
        i = i + 1;
    }
    console_putc(10);
}

fn fs_remove(name: str) -> int {
    let i: int = fs_find(name);
    if (i < 0) {
        return -1;
    }
    fs_used[i] = 0;
    return 0;
}

/* Library OS facade. Raw fs_* slot functions remain for the ppdb host adapter. */
struct FileHandle {
    id: int,
}

fn file_open(name: str) -> FileHandle {
    let handle: FileHandle;
    handle.id = fs_find(name);
    return handle;
}

fn file_open_or_create(name: str) -> FileHandle {
    let handle: FileHandle = file_open(name);
    if (handle.id < 0) {
        handle.id = fs_create(name);
    }
    return handle;
}

fn file_is_valid(handle: FileHandle) -> bool {
    return handle.id >= 0;
}

fn file_read_all(handle: FileHandle, destination: u64) -> int {
    if (!file_is_valid(handle)) {
        return -1;
    }
    return fs_read(handle.id, destination as int);
}

fn file_write_text(handle: FileHandle, data: str) -> bool {
    if (!file_is_valid(handle)) {
        return false;
    }
    fs_write(handle.id, data);
    return true;
}

fn file_write_bytes(handle: FileHandle, data: u64, size: int) -> bool {
    if (!file_is_valid(handle)) {
        return false;
    }
    fs_write_bin(handle.id, data as int, size);
    return true;
}

fn file_print(handle: FileHandle) -> bool {
    if (!file_is_valid(handle)) {
        return false;
    }
    fs_print(handle.id);
    return true;
}

fn file_remove(name: str) -> bool {
    return fs_remove(name) == 0;
}

fn file_list() {
    fs_list();
}

fn file_list_to_buffer(destination: u64, capacity: int) -> int {
    let writer: BoundedWriter = writer_new(destination, capacity);
    let first: bool = true;
    let i: int = 0;
    while (i < 16 && !writer.failed) {
        if (fs_used[i] == 1) {
            if (!first) {
                writer_write_byte(&writer, 44);
            }
            first = false;
            let j: int = 0;
            while (j < 32 && fs_name[i][j] != 0) {
                writer_write_byte(&writer, fs_name[i][j]);
                j = j + 1;
            }
        }
        i = i + 1;
    }
    if (!writer_terminate(&writer)) {
        return -1;
    }
    return writer.len;
}
