/* app.pp：pp-os 应用程序模型——"程序 = 协程 + 库"的落地。
   内核 = 机制（fs/net/tls/json/协程/注册表）；app = 策略（browse/ds/sql/...）。
   注册表 = 名字/描述/id；入口经 app_dispatch 分发（编译期注册，id 与注册顺序一致）。 */

static app_name: [int; 8];   /* 名字指针（int 存指针） */
static app_desc: [int; 8];   /* 描述指针 */
static app_count: int = 0;

/* 注册 app，返回 id（与 app_dispatch 分支顺序一致） */
fn app_register(name: str, desc: str) -> int {
    if (app_count < 8) {
        app_name[app_count] = ptr_to_int(name);
        app_desc[app_count] = ptr_to_int(desc);
        app_count = app_count + 1;
        return app_count - 1;
    }
    return -1;
}

/* 按 id 分发到 app 入口（id 与 app_register 调用顺序一致） */
fn app_dispatch(id: int) {
    if (id == 0) {
        browse_main();
    } else if (id == 1) {
        ds_main();
    } else if (id == 2) {
        cmd_sql();   /* 无参数时打印用法 */
    } else if (id == 3) {
        cmd_db();    /* 无参数时打印用法 */
    }
}

/* 查找 app 名字（s 指向名字字符串），返回 id，未找到返回 -1 */
fn app_find(s: int) -> int {
    let i: int = 0;
    while (i < app_count) {
        if (str_eq(app_name[i], int_to_ptr(s)) == 1) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

/* app run <name> */
fn app_cmd_run(arg: int) {
    let id: int = app_find(arg);
    if (id >= 0) {
        app_dispatch(id);
    } else {
        serial_print("app: no such app\n");
    }
}

/* app list */
fn app_cmd_list() {
    let i: int = 0;
    while (i < app_count) {
        let j: int = 0;
        while (volatile_load8(app_name[i] + j) != 0) {
            serial_putc(volatile_load8(app_name[i] + j));
            j = j + 1;
        }
        serial_putc(32);
        j = 0;
        while (volatile_load8(app_desc[i] + j) != 0) {
            serial_putc(volatile_load8(app_desc[i] + j));
            j = j + 1;
        }
        serial_putc(10);
        i = i + 1;
    }
}

/* app help <name> */
fn app_cmd_help(arg: int) {
    let id: int = app_find(arg);
    if (id >= 0) {
        let j: int = 0;
        while (volatile_load8(app_desc[id] + j) != 0) {
            serial_putc(volatile_load8(app_desc[id] + j));
            j = j + 1;
        }
        serial_putc(10);
    } else {
        serial_print("app: no such app\n");
    }
}
