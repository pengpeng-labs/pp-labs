# ppos App Model

> 本文是 ppos Native/WASM 应用边界的权威契约。实现路线见 `docs/roadmap.md` Phase 21。

ppos 是单地址空间、全部 ring0 的教学型 unikernel。它没有 Unix process、fork/exec 或 syscall 边界；应用通过 Library OS API 使用系统能力。这里的边界首先用于结构、测试和审计，只有 WASM runtime 完成 validation、bounds、trap、fuel 后才形成软件隔离边界。

## 1. 四层结构

```text
Applications
  Native: shell / browser / agent / ppdb
  Dynamic: WASM module + manifest
        |
App Runtime
  descriptor / lifecycle / task / capability / terminal
        |
Library OS Services
  console / fs / net / TLS / JSON / MCP / DB
        |
Kernel Mechanisms
  trap / memory / scheduler / sync / device
```

判断规则：

- trap、页、task、driver 属于 kernel mechanism；
- console、FS、network、TLS 和 DB 以有界 API 组成 Library OS；
- shell 命令、网页呈现、Agent 循环和数据库交互属于 App policy；
- App 不通过固定物理地址共享参数或输出；
- C 库只通过小型 glue ABI 进入 Library OS，不直接成为 App API。

## 2. Native App

Native App 不是 Library。Library OS service 是被链接和调用的库；Native App 是具有入口、生命周期和能力声明的程序模块，静态链接进同一个 image。

```text
Native App
  = AppDescriptor
  + entry function
  + AppContext
  + coroutine task
  + linked service dependencies
```

R3-1/R3-2 已落地 descriptor 与 context，R3-3 已落地其执行所需的 task runtime：

```pp
struct AppDescriptor {
    name: str,
    description: str,
    entry: fn(*AppContext) -> int,
    capabilities: u64,
    stack_size: int,
}
struct AppContext {
    terminal: u64,
    args: str,
    capabilities: u64,
}

```

`AppDescriptor` 由静态 image profile 注册。runtime 通过函数指针调用 `entry`，注册顺序不再和分发分支形成隐式 ABI。每个 descriptor 当前拥有 256B 参数槽；runtime 先复制 source，再构造带真实长度的 `args`。`terminal=0` 在 R4 前表示“无 terminal handle”，不是物理 console 的伪 handle。

### 生命周期

```text
Registered
  -> start(args, terminal)
  -> Runnable <-> Waiting
  -> Dead(exit_code)
  -> resources reclaimed
```

- 每个 App 有独立 coroutine stack 和 task record；
- `AppContext.args` 在 App 生命周期内有效，不指向 shell 的临时命令缓冲；
- 正常返回产生 exit code；首版没有 unwind，kernel panic 会停止整个 image，Native memory corruption 也仍可破坏整个 image；
- terminal、timer、FS 和 network wait 通过 runtime/service API，不由 App 直接轮询硬件；
- 首版仍为 cooperative scheduling，不承诺抢占或并行执行。

R3-3 task table 固定为 8 槽，状态为 `Unused/Runnable/Waiting{event,deadline}/Dead(exit_code)`。栈由 kernel allocator 分配，entry 返回后由 trampoline 收集退出码，再由其他 task 回收。scheduler 采用 round-robin；wait 可等待 event、`u64` PIT deadline，或两者任一先到。IRQ 不直接切 task 或遍历 waiters，后续 R4 由 IRQ 写 event queue、cooperative runtime 消费并唤醒。

### Capability 的含义

首版 capability 是显式 API 纪律和审计元数据，例如：

```text
CONSOLE_READ / CONSOLE_WRITE
FS_READ / FS_WRITE
NET_HTTP
DB_READ / DB_WRITE
CLOCK
```

R3-5 将在取得 service handle/调用受控 facade 时检查 capability。由于 Native App 与 kernel 共享 ring0 地址空间，它不是安全沙箱；即使 gate 完成，文档和 UI 也不得把 Native capability 描述成硬件隔离。

## 3. WASM App

WASM App 用于动态安装和低信任代码：

```text
WASM App
  = module bytes
  + manifest
  + validated instance
  + private linear memory
  + instruction fuel
  + capability-filtered Host ABI
```

Manifest 至少声明 name、entry export、memory limit、fuel 和 capabilities。Host ABI 只传 handle、linear-memory offset、length 和 error code，不暴露 kernel raw address：

```text
pp.console.write
pp.clock.now
pp.fs.open/read/write
pp.net.http
pp.db.sql/kv/doc
```

生命周期：

```text
FS module + manifest
  -> parse
  -> validate
  -> instantiate(memory, imports, fuel)
  -> run/resume
  -> exit or app-local trap
  -> destroy instance
```

当前 `wasm.pp` 只是 trusted demo。完成 section/type/import validation、operand/local/call/memory bounds、统一 trap、fuel 和 malformed corpus 前，不运行不可信模块，也不宣称沙箱能力。

## 4. Terminal 与 Workspace

App 只面向 `Terminal`：

```text
read_event() -> KeyEvent
write(bytes) -> Result[int, IoError]
flush()
size() -> (int, int)
```

Text Workspace 决定 terminal 显示在哪个 pane；VGA text 和 serial ANSI 是 renderer。Native 输出与 WASM `fd_write` 汇入相同 terminal，正常 App 不直接调用 `outb(0x3f8)` 或写 `0xb8000`。panic console 是例外，它可直接接管物理输出。

## 5. Library OS API 规则

Service API 必须满足：

- pointer 参数同时携带 length/capacity，或使用 `str`/typed wrapper；
- 返回值使用明确的数量、handle 或 Sum Type，不用魔法全局缓冲；
- ownership 和有效期写在接口旁；
- 可等待操作返回状态并允许 task yield；
- App 不访问 driver/MMIO、PIC/PIT、page table 和 allocator metadata；
- API secret 不进入普通可列举文件或日志。

建议结果类型：

```pp
enum ServiceError {
    Invalid,
    Denied,
    NotFound,
    NoSpace,
    TimedOut,
    Failed(int),
}

enum ServiceResult[T] {
    Ok(T),
    Err(ServiceError),
}
```

## 6. C Glue 边界

uIP 和 BearSSL 保持现状，通过以下单向边界接入：

```text
read-only upstream C
  -> freestanding static library
  -> handwritten *_glue.c
  -> narrow extern ABI
  -> pplang typed service wrapper
  -> App API
```

extern ABI 只使用固定宽度整数、`u64` address、pointer + length、POD struct 和 error code。glue 必须记录 ownership、capacity、callback lifetime、reentrancy 和 blocking 假设。不得为了接入某个库新增 pplang 语法。

## 7. 当前实现与迁移

当前实现已具备 typed service、descriptor/context、通用 task mechanism 与统一 Native App 生命周期：

- R2-2/R2-3 已建立 typed service 与 `BoundedWriter`；browser/agent/MCP/shell 不再引用 service response 魔法地址或 ppdb 原始 API，HTTP/TLS/Agent/JSON/MCP 拼装均有显式 capacity；
- R2-4 已建立 8KiB kernel log ring 和带 wrap/lost 语义的 cursor 输入；正常 console 在 R4 前仍镜像到 serial，panic/exception 绕过 ring 与 lock 独占 raw UART；
- R2-5 已为 uIP/BearSSL 建立可执行 C glue 合同：地址为 `u64`、buffer 必带 length/capacity、发送失败原子化、callback 同步借用且不可重入、TLS 单会话；至此 Library OS Boundary 阶段完成；
- R3-1/R3-2 已使用 `AppDescriptor`、`AppContext` 和 `fn(*AppContext) -> int`；`app_dispatch(id)` 已删除，App args 复制进 runtime-owned slot；
- R3-3 已建立 8 槽 task table、独立栈、return trampoline、yield、event/deadline wait 和 reap；
- R3-4 已建立 `Registered/Running/Exited/Failed` App 状态和 typed wait result；bootstrap task 0 只作 supervisor，shell/browser/agent/sql/db 都运行在独立 task stack；
- shell parser 自身仍拥有 `0x400200/0x400300`，但 App Runtime 会复制 args；db frontend 使用模块私有 token/result scratch，registered App entry 不读取或保存 shell 地址；
- ppos 自有模块已走 console facade，嵌入 ppdb 仍通过 `serial_*` 兼容入口输出；
- network/TLS response buffer 已由 service-owned view 隐藏；Agent module-owned workspace 有显式容量与失败语义；
- heartbeat 与所有 registered App 都使用独立 task stack；
- WASM `fd_write` 直接写 serial。

迁移顺序固定为：

1. R1 建立可靠 trap、64 位 context、memory map 和 allocator；
2. R2 建立 typed service、bounded buffer、log ring；
3. R3 引入 `AppDescriptor`、`AppContext`、task table；
4. 迁移 shell/browser/agent/ppdb；
5. R4 接入 Text Workspace terminal；
6. R5 将 WASM 从 trusted demo 提升为有界 runtime。

R3-1~R3-4 已完成 descriptor、owned context、task mechanism 和 shell/browser/agent/ppdb 生命周期迁移。下一步 R3-5 为 typed service facade 增加 capability gate，同时重申它只是同一 ring0 trust domain 内的 API 纪律，不是隔离边界。
