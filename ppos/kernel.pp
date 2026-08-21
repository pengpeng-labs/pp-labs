extern fn load_idt();
extern fn trigger_invalid_opcode();
extern fn exception_selftest_enabled() -> int;
extern fn allocator_selftest_enabled() -> int;
extern fn kernel_permissions_ok() -> int;
extern fn kernel_stack_alignment_ok() -> int;
extern fn interrupt_register_selftest() -> int;

import "fs.pp";
import "db_service.pp";
import "kernel_console.pp";
import "kernel_irq.pp";
import "kernel_memory.pp";
import "kernel_shell.pp";
import "kernel_task.pp";
import "libos.pp";
import "net.pp";
import "tls.pp";
import "json.pp";
import "agent.pp";
import "browser.pp";
import "app.pp";
import "mcp.pp";
import "wasm.pp";
import "../ppdb/db_core.pp";
import "../ppdb/host_ppos.pp";
import "../ppdb/host_file_ppos.pp";
import "../ppdb/db_sql_parse.pp";
import "../ppdb/db_sql_exec.pp";
import "../ppdb/db_kv.pp";
import "../ppdb/db_doc.pp";
import "../ppdb/db_tx.pp";
import "../ppdb/db_persist.pp";

fn kmain(multiboot_magic: u64, multiboot_info: u64) -> int {
    if (!kernel_log_selftest()) {
        kernel_panic("kernel log ring selftest failed");
    }
    console_write("PP-OS\n");
    if (exception_selftest_enabled() == 1) {
        trigger_invalid_opcode();
    }
    if (!memory_map_init(multiboot_magic, multiboot_info)) {
        console_write("memory map error=");
        print_int(memory_map_error);
        console_write(" magic=0x");
        serial_print_hex64(multiboot_magic);
        console_write(" info=0x");
        serial_print_hex64(multiboot_info);
        if (multiboot_info != (0 as u64)) {
            console_write(" flags=0x");
            serial_print_hex64((volatile_load32(multiboot_info) as u32) as u64);
        }
        console_putc(10);
        kernel_panic("invalid Multiboot memory map or reserved-region overlap");
    }
    if (kernel_permissions_ok() != 1 || kernel_stack_alignment_ok() != 1) {
        kernel_panic("kernel W^X/NX or stack alignment check failed");
    }
    if (!writer_selftest()) {
        kernel_panic("bounded writer selftest failed");
    }
    if (!glue_contract_selftest()) {
        kernel_panic("C glue contract selftest failed");
    }
    console_write("GLUE CONTRACT PASS\n");
    console_write("memory: usable_end=0x");
    serial_print_hex64(usable_memory_end);
    console_write(" regions=");
    print_int(memory_region_count);
    console_putc(10);
    if (allocator_selftest_enabled() == 1) {
        if (!allocator_selftest()) {
            console_write("allocator test error=");
            print_int(allocator_test_error);
            console_putc(10);
            kernel_panic("allocator selftest failed");
        }
        console_write("ALLOCATOR TEST PASS\n");
        cli();
        while (true) { hlt(); }
    }
    pic_remap();
    if (interrupt_register_selftest() != 1) {
        kernel_panic("interrupt register preservation failed");
    }
    /* PIT 定时器：100Hz（1193182/100 = 11931 = 0x2E9B），让 hlt/轮询以 ~10ms 粒度工作 */
    outb(0x43, 0x36);
    outb(0x40, 0x9B);
    outb(0x40, 0x2E);
    sti();
    fs_init();
    net_init();
    task_init();
    if (!task_runtime_selftest()) {
        kernel_panic("task table/event/deadline selftest failed");
    }
    console_write("TASK RUNTIME PASS\n");
    if (!app_runtime_selftest()) {
        kernel_panic("App descriptor/context/lifecycle selftest failed");
    }
    console_write("APP DESCRIPTOR PASS\n");
    console_write("APP CONTEXT PASS\n");
    console_write("APP LIFECYCLE PASS\n");
    /* Capability bits are audit metadata until R3-5 service gates land. */
    let shell_id: int = app_register("shell", "interactive command shell",
        &shell_app_entry, 254 as u64, 32768);
    let browse_id: int = app_register("browse", "CLI web browser (text render)",
        &browse_app_entry, 146 as u64, 16384);
    let ds_id: int = app_register("ds", "DeepSeek chat agent",
        &ds_app_entry, 246 as u64, 32768);
    let sql_id: int = app_register("sql", "SQL queries (CREATE/INSERT/SELECT/UPDATE/DELETE/DROP)",
        &sql_app_entry, 98 as u64, 16384);
    let db_id: int = app_register("db", "pp-db console (put/get/del/list/create/drop/doc)",
        &db_app_entry, 110 as u64, 16384);
    if (shell_id < 0 || browse_id < 0 || ds_id < 0 || sql_id < 0 || db_id < 0) {
        kernel_panic("native app profile registration failed");
    }
    /* 注册 MCP 工具（id 与 mcp_run_tool 分支一致） */
    mcp_register("ls", "List files in the pp-os file system");
    mcp_register("sql", "Execute SQL (CREATE/INSERT/SELECT/UPDATE/DELETE/DROP) against pp-db; param: sql");
    mcp_register("kv", "Key-value store ops; params: op (get/put/del), key, value");
    mcp_register("doc", "JSON document store ops; params: op (get/put), name, content");

    /* Heartbeat and shell both own independent task stacks. */
    if (task_create(&heartbeat, 0 as u64, 4096) < 1) {
        kernel_panic("out of memory allocating coroutine stack");
    }
    if (app_start_index(shell_id, 0 as u64, 0) < 1) {
        kernel_panic("failed to start shell Native App");
    }
    console_write("PPOS READY\n");
    /* Bootstrap task 0 is the scheduler supervisor, not the shell. */
    while (true) {
        hlt();
        task_yield();
    }
    return 0;
}
