/* host_file_ppos.pp：pp-db 文件抽象——pp-os 宿主实现（包 fs_*）。
   db_persist 只依赖本文件声明的 5 个函数，与具体文件系统解耦：
     hf_find(name: str) -> int             找文件，-1 不存在
     hf_create(name: str) -> int           建新文件（空），-1 失败
     hf_write(idx: int, data: u64, len: int)    从开头写（截断语义）
     hf_write_at(idx: int, data: u64, len: int, off: int)  偏移写
     hf_read_at(idx: int, buf: u64, len: int, off: int) -> int  区间读，返回实际字节数
   数据指针用 u64（地址通道 64 位）；pp-os 内核低地址经 coerce 截断无损。 */

fn hf_find(name: str) -> int {
    return fs_find(name);
}

fn hf_create(name: str) -> int {
    return fs_create(name);
}

fn hf_write(idx: int, data: u64, len: int) {
    fs_write_bin(idx, data, len);
}

fn hf_write_at(idx: int, data: u64, len: int, off: int) {
    fs_write_bin_at(idx, data, len, off);
}

fn hf_read_at(idx: int, buf: u64, len: int, off: int) -> int {
    return fs_read_at(idx, buf, len, off);
}
