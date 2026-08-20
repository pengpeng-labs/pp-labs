/* host_file_native.pp：pp-db 文件抽象——宿主机实现（POSIX open/write/read/lseek/close）。
   与 host_file_ppos 同签名，实现换成真实文件：
     hf_find(name: str) -> int             找文件，-1 不存在
     hf_create(name: str) -> int           建新文件（空），-1 失败
     hf_write(idx: int, data: u64, len: int)    从开头写（截断语义）
     hf_write_at(idx: int, data: u64, len: int, off: int)  偏移写
     hf_read_at(idx: int, buf: u64, len: int, off: int) -> int  区间读，返回实际字节数
   idx 即 POSIX fd；数据指针用 u64（宿主机静态地址 >4GB 无损）。
   文本路径使用 str（FFI 时传 ptr），任意二进制缓冲使用裸指针 *u8。 */

extern fn open(path: str, flags: int, mode: int) -> int;
extern fn write(fd: int, buf: *u8, len: u64) -> int;
extern fn read(fd: int, buf: *u8, len: u64) -> int;
extern fn lseek(fd: int, off: u64, whence: int) -> int;
extern fn close(fd: int) -> int;
extern fn fchmod(fd: int, mode: int) -> int;

/* POSIX flags：O_RDONLY=0；macOS O_CREAT=0x200 O_TRUNC=0x400（Linux 0x40/0x200）
   O_RDWR=2 + O_CREAT + O_TRUNC；mode 0644。
   注：open 是 variadic（int open(const char*, int, ...)），pp 按固定三参声明调用时
   mode 在部分 ABI 下传递错乱（文件权限异常 0001/0400）——不影响读写，仅权限怪异。
   hf_find 用 O_RDWR 打开（文件属本程序，可写打开同时可读）。 */
fn hf_find(name: str) -> int {
    return open(name, 2, 0);
}

fn hf_create(name: str) -> int {
    let fd: int = open(name, 2 | 512 | 1024, 420);
    if (fd < 0) {
        return -1;
    }
    /* open 是 variadic：mode 在 ARM64 上传递错乱（权限 0000）——
       创建后显式 fchmod 设 0644（非 variadic，参数可靠） */
    fchmod(fd, 420);
    return fd;
}

fn hf_write(idx: int, data: u64, len: int) {
    let w: int = 0;
    while (w < len) {
        let n: int = write(idx, (data + w) as *u8, len - w);
        if (n <= 0) {
            return;
        }
        w = w + n;
    }
}

fn hf_write_at(idx: int, data: u64, len: int, off: int) {
    lseek(idx, off, 0);
    hf_write(idx, data, len);
}

fn hf_read_at(idx: int, buf: u64, len: int, off: int) -> int {
    lseek(idx, off, 0);
    let r: int = read(idx, buf as *u8, len);
    if (r < 0) {
        return 0;
    }
    return r;
}
