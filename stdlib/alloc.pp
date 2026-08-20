/* alloc.pp：显式分配器。
   宿主机 = libc malloc/free（JIT dlsym 或 cc 链接解析）。
   pp-os 不用本文件，直接用内核 kmalloc/kfree（free-list，见 ppos/kernel.pp）。 */

extern fn malloc(size: u64) -> *u8;
extern fn free(ptr: *u8);

/* 分配 size 字节，返回裸指针。失败返回 0（null）。 */
fn alloc(size: int) -> *u8 {
    return malloc(size as u64);
}

/* 释放 alloc 返回的指针。 */
fn dealloc(ptr: *u8) {
    free(ptr);
}
