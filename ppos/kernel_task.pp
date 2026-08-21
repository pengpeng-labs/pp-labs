/* Cooperative task table with owned stacks, waits, deadlines and exit state. */

extern fn switch_context(old_sp_addr: u64, new_sp: u64);
extern fn make_context(stack_top: u64, func: u64) -> u64;

struct TaskWait {
    event: int,
    deadline: u64,
}

enum TaskState {
    Unused,
    Runnable,
    Waiting(TaskWait),
    Dead(int),
}

struct TaskRecord {
    state: TaskState,
    saved_rsp: u64,
    stack_base: u64,
    stack_size: int,
    entry: fn(u64) -> int,
    argument: u64,
}

static task_table: [8]TaskRecord;
static task_current: int = 0;
static task_selftest_stage: int = 0;

fn task_state_runnable(id: int) -> bool {
    switch task_table[id].state {
        TaskState.Runnable { return true; }
        _ { return false; }
    }
    return false;
}

fn task_state_unused(id: int) -> bool {
    switch task_table[id].state {
        TaskState.Unused { return true; }
        _ { return false; }
    }
    return false;
}

fn task_state_dead(id: int) -> bool {
    switch task_table[id].state {
        TaskState.Dead(code) { return true; }
        _ { return false; }
    }
    return false;
}

fn task_exit_code(id: int) -> int {
    switch task_table[id].state {
        TaskState.Dead(code) { return code; }
        _ { return -1; }
    }
    return -1;
}

fn task_init() {
    let i: int = 0;
    while (i < 8) {
        task_table[i].state = TaskState.Unused();
        task_table[i].saved_rsp = 0 as u64;
        task_table[i].stack_base = 0 as u64;
        task_table[i].stack_size = 0;
        task_table[i].argument = 0 as u64;
        i = i + 1;
    }
    task_table[0].state = TaskState.Runnable();
    task_current = 0;
}

fn task_trampoline() {
    let id: int = task_current;
    let entry: fn(u64) -> int = task_table[id].entry;
    let exit_code: int = entry(task_table[id].argument);
    task_table[id].state = TaskState.Dead(exit_code);
    task_yield();
    kernel_panic("dead task resumed");
}

fn task_create(entry: fn(u64) -> int, argument: u64, stack_size: int) -> int {
    if (stack_size < 4096) {
        return -1;
    }
    let id: int = 1;
    while (id < 8 && !task_state_unused(id)) {
        id = id + 1;
    }
    if (id >= 8) {
        return -1;
    }
    let stack_base: u64 = kmalloc(stack_size);
    if (stack_base == (0 as u64)) {
        return -1;
    }
    let saved_rsp: u64 = make_context(stack_base + (stack_size as u64), &task_trampoline);
    if (saved_rsp == (0 as u64)) {
        kfree(stack_base);
        return -1;
    }
    task_table[id].saved_rsp = saved_rsp;
    task_table[id].stack_base = stack_base;
    task_table[id].stack_size = stack_size;
    task_table[id].entry = entry;
    task_table[id].argument = argument;
    task_table[id].state = TaskState.Runnable();
    return id;
}

fn task_poll_deadlines() {
    let now: u64 = tick_count_global();
    let id: int = 1;
    while (id < 8) {
        switch task_table[id].state {
            TaskState.Waiting(wait) {
                if (wait.deadline > (0 as u64) && now >= wait.deadline) {
                    task_table[id].state = TaskState.Runnable();
                }
            }
            _ { }
        }
        id = id + 1;
    }
}

fn task_next_runnable() -> int {
    let offset: int = 1;
    while (offset < 8) {
        let id: int = (task_current + offset) % 8;
        if (task_state_runnable(id)) {
            return id;
        }
        offset = offset + 1;
    }
    return -1;
}

fn task_yield() {
    task_poll_deadlines();
    let next: int = task_next_runnable();
    if (next < 0 || next == task_current) {
        return;
    }
    let old: int = task_current;
    let old_slot: u64 = ptr_to_int(&task_table[old].saved_rsp);
    task_current = next;
    switch_context(old_slot, task_table[next].saved_rsp);
}

/* event=0 means timer-only; timeout=0 means event-only. */
fn task_wait(event: int, timeout_ticks: int) -> bool {
    if (task_current == 0 || event < 0 || timeout_ticks < 0
        || (event == 0 && timeout_ticks == 0)) {
        return false;
    }
    let wait: TaskWait;
    wait.event = event;
    wait.deadline = 0 as u64;
    if (timeout_ticks > 0) {
        wait.deadline = tick_count_global() + (timeout_ticks as u64);
    }
    task_table[task_current].state = TaskState.Waiting(wait);
    task_yield();
    return task_state_runnable(task_current);
}

/* Called from cooperative policy context, never directly from an IRQ. */
fn task_wake_event(event: int) -> int {
    if (event <= 0) {
        return 0;
    }
    let count: int = 0;
    let id: int = 1;
    while (id < 8) {
        switch task_table[id].state {
            TaskState.Waiting(wait) {
                if (wait.event == event) {
                    task_table[id].state = TaskState.Runnable();
                    count = count + 1;
                }
            }
            _ { }
        }
        id = id + 1;
    }
    return count;
}

fn task_reap(id: int) -> bool {
    if (id <= 0 || id >= 8 || !task_state_dead(id)) {
        return false;
    }
    if (task_table[id].stack_base != (0 as u64)) {
        if (!kfree(task_table[id].stack_base)) {
            return false;
        }
    }
    task_table[id].state = TaskState.Unused();
    task_table[id].saved_rsp = 0 as u64;
    task_table[id].stack_base = 0 as u64;
    task_table[id].stack_size = 0;
    task_table[id].argument = 0 as u64;
    return true;
}

fn task_selftest_worker(argument: u64) -> int {
    if (argument != (99 as u64)) {
        return -3;
    }
    task_selftest_stage = 1;
    if (!task_wait(42, 0)) {
        return -1;
    }
    task_selftest_stage = 2;
    if (!task_wait(0, 2)) {
        return -2;
    }
    task_selftest_stage = 3;
    return 37;
}

fn task_runtime_selftest() -> bool {
    task_selftest_stage = 0;
    let id: int = task_create(&task_selftest_worker, 99 as u64, 4096);
    if (id < 1) {
        return false;
    }
    task_yield();
    if (task_selftest_stage != 1 || task_wake_event(42) != 1) {
        return false;
    }
    task_yield();
    if (task_selftest_stage != 2) {
        return false;
    }
    let guard: int = 0;
    while (task_selftest_stage != 3 && guard < 100) {
        hlt();
        task_yield();
        guard = guard + 1;
    }
    if (task_selftest_stage != 3) {
        return false;
    }
    task_yield();
    if (!task_state_dead(id) || task_exit_code(id) != 37) {
        return false;
    }
    return task_reap(id) && task_state_unused(id);
}
