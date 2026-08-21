/* Native App descriptor registry and owned invocation context. */

struct AppContext {
    terminal: u64,
    args: str,
    capabilities: u64,
}

struct AppDescriptor {
    name: str,
    description: str,
    entry: fn(*AppContext) -> int,
    capabilities: u64,
    stack_size: int,
}

enum AppState {
    Registered,
    Running(int),
    Exited(int),
    Failed(int),
}

struct AppWaitResult {
    ok: bool,
    code: int,
}

/* Capability audit bits: console.write=1, fs.read=2, fs.write=3,
   net.http=4, db.read=5, db.write=6, clock=7. Enforcement is R3-5. */

static app_registry: [8]AppDescriptor;
static app_context: [8]AppContext;
static app_args: [2048]u8;
static app_state: [8]AppState;
static app_count: int = 0;
static app_selftest_value: int = 0;

fn app_register(name: str, description: str, entry: fn(*AppContext) -> int,
    capabilities: u64, stack_size: int) -> int {
    if (app_count >= 8 || stack_size < 4096) {
        return -1;
    }
    app_registry[app_count].name = name;
    app_registry[app_count].description = description;
    app_registry[app_count].entry = entry;
    app_registry[app_count].capabilities = capabilities;
    app_registry[app_count].stack_size = stack_size;
    app_state[app_count] = AppState.Registered();
    app_count = app_count + 1;
    return app_count - 1;
}

fn app_prepare_context(id: int, source: u64, size: int) -> *AppContext {
    if (id < 0 || id >= app_count || size < 0 || size > 255
        || (size > 0 && source == (0 as u64))) {
        return 0 as *AppContext;
    }
    let destination: u64 = ptr_to_int(&app_args[0]) + id * 256;
    let i: int = 0;
    while (i < size) {
        volatile_store8(destination + i, volatile_load8(source + i));
        i = i + 1;
    }
    volatile_store8(destination + size, 0);
    app_context[id].terminal = 0 as u64;
    app_context[id].args = str_from_ptr(int_to_ptr(destination), size);
    app_context[id].capabilities = app_registry[id].capabilities;
    return &app_context[id];
}

fn app_invoke(id: int, context: *AppContext) -> int {
    if (id < 0 || id >= app_count) {
        return -1;
    }
    let entry: fn(*AppContext) -> int = app_registry[id].entry;
    return entry(context);
}

fn app_is_running(id: int) -> bool {
    if (id < 0 || id >= app_count) {
        return false;
    }
    let state: AppState = app_state[id];
    switch state {
        AppState.Running(task_id) { return true; }
        _ { return false; }
    }
    return false;
}

fn app_task_id(id: int) -> int {
    if (id < 0 || id >= app_count) {
        return -1;
    }
    let state: AppState = app_state[id];
    switch state {
        AppState.Running(task_id) { return task_id; }
        _ { return -1; }
    }
    return -1;
}

fn app_finished_code(id: int) -> int {
    if (id < 0 || id >= app_count) {
        return -1;
    }
    let state: AppState = app_state[id];
    switch state {
        AppState.Exited(code) { return code; }
        AppState.Failed(code) { return code; }
        _ { return -1; }
    }
    return -1;
}

fn app_task_entry(argument: u64) -> int {
    let id: int = argument as int;
    if (id < 0 || id >= app_count) {
        return -1;
    }
    let exit_code: int = app_invoke(id, &app_context[id]);
    if (exit_code == 0) {
        app_state[id] = AppState.Exited(exit_code);
    } else {
        app_state[id] = AppState.Failed(exit_code);
    }
    return exit_code;
}

/* Returns a positive task id, or a stable negative start error. */
fn app_start_index(id: int, source: u64, size: int) -> int {
    if (id < 0 || id >= app_count) {
        return -1;
    }
    if (size < 0 || size > 255 || (size > 0 && source == (0 as u64))) {
        return -3;
    }
    if (app_is_running(id)) {
        return -2;
    }
    let context: *AppContext = app_prepare_context(id, source, size);
    if (context == (0 as *AppContext)) {
        return -3;
    }
    let task_id: int = task_create(&app_task_entry, id as u64,
        app_registry[id].stack_size);
    if (task_id < 1) {
        app_state[id] = AppState.Failed(-4);
        return -4;
    }
    app_state[id] = AppState.Running(task_id);
    return task_id;
}

fn app_wait_index(id: int) -> AppWaitResult {
    let result: AppWaitResult;
    result.ok = false;
    result.code = 0;
    let task_id: int = app_task_id(id);
    if (task_id < 1) {
        if (id < 0 || id >= app_count) {
            return result;
        }
        let state: AppState = app_state[id];
        switch state {
            AppState.Exited(code) {
                result.ok = true;
                result.code = code;
            }
            AppState.Failed(code) {
                result.ok = true;
                result.code = code;
            }
            _ { }
        }
        return result;
    }
    while (!task_state_dead(task_id)) {
        hlt();
        task_yield();
    }
    let exit_code: int = task_exit_code(task_id);
    if (!task_reap(task_id)) {
        app_state[id] = AppState.Failed(-5);
        return result;
    }
    result.ok = true;
    result.code = exit_code;
    return result;
}

fn app_run_index(id: int, source: u64, size: int) -> int {
    let started: int = app_start_index(id, source, size);
    if (started < 1) {
        return started;
    }
    let result: AppWaitResult = app_wait_index(id);
    if (!result.ok) {
        return -5;
    }
    return result.code;
}

fn app_find(name: u64) -> int {
    let i: int = 0;
    while (i < app_count) {
        if (str_eq(name, app_registry[i].name) == 1) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn app_cmd_run(name: u64, args: u64, args_len: int) {
    let id: int = app_find(name);
    if (id < 0) {
        console_write("app: no such app\n");
        return;
    }
    let started: int = app_start_index(id, args, args_len);
    if (started == -2) {
        console_write("app: already running\n");
        return;
    }
    if (started == -3) {
        console_write("app: arguments too large\n");
        return;
    }
    if (started < 1) {
        console_write("app: runtime start failure\n");
        return;
    }
    let result: AppWaitResult = app_wait_index(id);
    if (!result.ok) {
        console_write("app: runtime reap failure\n");
        return;
    }
    let exit_code: int = result.code;
    if (exit_code == 0) {
        console_write("app exit=");
    } else {
        console_write("app failed=");
    }
    print_int(exit_code);
    console_putc(10);
}

fn app_print_metadata(id: int) {
    console_write(" caps=0x");
    serial_print_hex64(app_registry[id].capabilities);
    console_write(" [");
    let separator: bool = false;
    if ((app_registry[id].capabilities & (2 as u64)) != (0 as u64)) {
        console_write("console.write");
        separator = true;
    }
    if ((app_registry[id].capabilities & (4 as u64)) != (0 as u64)) {
        if (separator) { console_putc(44); }
        console_write("fs.read");
        separator = true;
    }
    if ((app_registry[id].capabilities & (8 as u64)) != (0 as u64)) {
        if (separator) { console_putc(44); }
        console_write("fs.write");
        separator = true;
    }
    if ((app_registry[id].capabilities & (16 as u64)) != (0 as u64)) {
        if (separator) { console_putc(44); }
        console_write("net.http");
        separator = true;
    }
    if ((app_registry[id].capabilities & (32 as u64)) != (0 as u64)) {
        if (separator) { console_putc(44); }
        console_write("db.read");
        separator = true;
    }
    if ((app_registry[id].capabilities & (64 as u64)) != (0 as u64)) {
        if (separator) { console_putc(44); }
        console_write("db.write");
        separator = true;
    }
    if ((app_registry[id].capabilities & (128 as u64)) != (0 as u64)) {
        if (separator) { console_putc(44); }
        console_write("clock");
    }
    console_putc(93);
    console_write(" stack=");
    print_int(app_registry[id].stack_size);
    console_write(" state=");
    let state: AppState = app_state[id];
    switch state {
        AppState.Registered { console_write("registered"); }
        AppState.Running(task_id) {
            console_write("running:");
            print_int(task_id);
        }
        AppState.Exited(code) {
            console_write("exited:");
            print_int(code);
        }
        AppState.Failed(code) {
            console_write("failed:");
            print_int(code);
        }
    }
}

fn app_cmd_list() {
    let i: int = 0;
    while (i < app_count) {
        console_write(app_registry[i].name);
        console_putc(32);
        console_write(app_registry[i].description);
        app_print_metadata(i);
        console_putc(10);
        i = i + 1;
    }
}

fn app_cmd_help(arg: u64) {
    let id: int = app_find(arg);
    if (id < 0) {
        console_write("app: no such app\n");
        return;
    }
    console_write(app_registry[id].name);
    console_write(": ");
    console_write(app_registry[id].description);
    app_print_metadata(id);
    console_putc(10);
}

fn app_selftest_entry(context: *AppContext) -> int {
    let args: str = context.args;
    if (context.terminal != (0 as u64)
        || context.capabilities != (0xA5 as u64)
        || len(args) != (4 as u64)
        || volatile_load8(ptr_to_int(args)) != 116) {
        return -1;
    }
    app_selftest_value = volatile_load8(ptr_to_int(args) + 1);
    return 23;
}

fn app_selftest_fail_entry(context: *AppContext) -> int {
    if (context.capabilities != (7 as u64)) {
        return -8;
    }
    return 9;
}

fn app_runtime_selftest() -> bool {
    app_count = 0;
    app_selftest_value = 0;
    let id: int = app_register("selftest", "descriptor dispatch probe",
        &app_selftest_entry, 0xA5 as u64, 4096);
    let source: [4]u8;
    source[0] = 116;
    source[1] = 101;
    source[2] = 115;
    source[3] = 116;
    let context: *AppContext = app_prepare_context(id, ptr_to_int(&source[0]), 4);
    source[0] = 88;
    let prepared_args: str = context.args;
    let direct_result: int = app_invoke(id, context);
    source[0] = 116;
    let started: int = app_start_index(id, ptr_to_int(&source[0]), 4);
    let reentrant_result: int = app_start_index(id, ptr_to_int(&source[0]), 4);
    let waited: AppWaitResult = app_wait_index(id);
    let exit_code: int = waited.code;
    let fail_id: int = app_register("failure", "failure state probe",
        &app_selftest_fail_entry, 7 as u64, 4096);
    let fail_exit: int = app_run_index(fail_id, 0 as u64, 0);
    let ok: bool = id == 0 && app_registry[0].capabilities == (0xA5 as u64)
        && app_registry[0].stack_size == 4096 && direct_result == 23
        && app_selftest_value == 101
        && volatile_load8(ptr_to_int(prepared_args)) == 116
        && started > 0 && waited.ok && exit_code == 23 && app_finished_code(id) == 23
        && reentrant_result == -2
        && app_run_index(id, ptr_to_int(&source[0]), 256) == -3
        && fail_exit == 9 && app_finished_code(fail_id) == 9;
    app_count = 0;
    return ok;
}
