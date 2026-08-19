/* main.pp：宿主机 CLI 测试入口（经 pp 编译器 run 运行）——P14-7 + D-1 文件持久化验证 */

import "db_core.pp";
import "db_kv.pp";
import "db_doc.pp";
import "db_persist.pp";
import "host_native.pp";
import "host_file_native.pp";

extern fn putchar(c: int) -> int;

fn serial_putc(c: int) {
    putchar(c);
}

fn serial_print(s: str) {
    let a: u64 = ptr_to_int(s);
    let i: int = 0;
    while (volatile_load8(a + i) != 0) {
        serial_putc(volatile_load8(a + i));
        i = i + 1;
    }
}

fn print_int(n: int) {
    if (n == 0) {
        serial_putc(48);
        return;
    }
    let buf: [12]u8;
    let i: int = 0;
    while (n > 0) {
        buf[i] = 48 + (n % 10);
        n = n / 10;
        i = i + 1;
    }
    while (i > 0) {
        i = i - 1;
        serial_putc(buf[i]);
    }
}

fn main() -> int {
    /* 1. 建表 t(int, str) + 插入 3 行 */
    let tid: int = db_create_table("t", 2, 0, 1, 0, 0);
    print_int(tid);
    serial_putc(10);
    let v1: [4]u64;
    let s1: str = "alice";
    let s2: str = "bob";
    let s3: str = "carol";
    v1[0] = 10;
    v1[1] = ptr_to_int(s1);
    print_int(db_insert(tid, ptr_to_int(&v1[0])));
    v1[0] = 20;
    v1[1] = ptr_to_int(s2);
    print_int(db_insert(tid, ptr_to_int(&v1[0])));
    v1[0] = 30;
    v1[1] = ptr_to_int(s3);
    print_int(db_insert(tid, ptr_to_int(&v1[0])));
    serial_putc(10);
    serial_print("[1] before save\n");
    /* 2. 存盘（真实文件 test.db） */
    db_save(ptr_to_int("test.db"));
    serial_print("[2] after save\n");
    /* 3. 删除表 + 清空 KV/Doc，模拟"重启丢失" */
    db_drop_table(0);
    serial_print("[3] after drop\n");
    /* 4. 重新加载 */
    db_load(ptr_to_int("test.db"));
    serial_print("[4] after load\n");
    /* 5. 扫描验证恢复 */
    let tid2: int = db_find_table(int_to_ptr(ptr_to_int("t")));
    print_int(tid2);
    serial_putc(10);
    if (tid2 >= 0) {
        db_scan_init(tid2);
        let rec: u64 = db_scan_next();
        while (rec != 0) {
            print_int(db_col(rec, tid2, 0));
            serial_putc(32);
            let sp: u64 = db_col(rec, tid2, 1);
            let k: int = 0;
            while (volatile_load8(sp + k) != 0) {
                serial_putc(volatile_load8(sp + k));
                k = k + 1;
            }
            serial_putc(10);
            rec = db_scan_next();
        }
    }
    return 0;
}
