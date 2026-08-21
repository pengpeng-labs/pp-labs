# ppos

ppos 是用 **pplang v0.3** 编写的教学型 x86-64 unikernel。

它用传统操作系统课程的方法实现 boot、trap、memory、task、driver、filesystem 和 network 等底层机制，再以 Library OS 形式向同一系统镜像中的应用提供服务。ppos 同时是 pplang/pplc 的裸机压力测试，也是 ppdb、Agent、MCP 和 WASM 的首个 freestanding 宿主。

> 目标：用传统 OS 知识建立可靠内核机制，用 unikernel/libOS 思想组织应用边界，最终把专用系统作为一个 x86-64 image 部署。

## 1. 系统定位

ppos 不是缩小版 Unix，也不只是一个能启动的 Agent demo。它的部署和信任模型是：

- 单一 x86-64 系统镜像；
- 单地址空间、全部 ring0；
- 无 Unix process、fork/exec、用户/权限和 POSIX syscall 层；
- Native App 与 ppos 静态链接，属于同一信任域；
- WASM App 通过受限 Host ABI 动态运行；
- 一个部署镜像选择一个 primary app，也可包含管理 shell 和多个协作式任务。

```text
┌─────────────────────────────────────────────────┐
│ Applications                                    │
│ Native: shell / agent / browser / ppdb          │
│ Dynamic: capability-limited WASM                │
├─────────────────────────────────────────────────┤
│ App Runtime + Text Workspace                    │
│ descriptor / lifecycle / coroutine / pane       │
├─────────────────────────────────────────────────┤
│ Library OS Services                             │
│ console / fs / net / TLS / JSON / MCP / DB      │
├─────────────────────────────────────────────────┤
│ Kernel Mechanisms                               │
│ trap / memory / task / sync / drivers           │
├─────────────────────────────────────────────────┤
│ x86-64 Platform                                 │
│ multiboot / paging / PIC / PIT / PCI / e1000    │
└─────────────────────────────────────────────────┘
```

“Library OS”在这里描述架构风格：OS 服务以库 API 链接进专用镜像。ppos 不是 Exokernel 上的用户态 ExOS，也没有 Drawbridge picoprocess 的进程隔离，因此不借这些术语暗示当前不存在的安全边界。

## 2. 理论与项目来源

### 传统操作系统主线

ppos 以 OSTEP、CSAPP、Patterson & Hennessy 和 xv6 为知识主线：

| 传统 OS 主题 | ppos 落点 |
|---|---|
| CPU 启动与执行级别 | Multiboot、32→64 位、GDT、页表 |
| trap 与 interrupt | IDT、exception、PIC、PIT、keyboard |
| 物理/虚拟内存 | memory map、page/heap、stack、guard |
| thread 与 scheduler | coroutine task、event、wait queue |
| synchronization | atomic、spinlock、task state |
| filesystem | VFS contract、ramfs、未来 block storage |
| device driver | VGA、UART、PCI、e1000、未来 block device |
| network | uIP、DNS、TCP、HTTP、BearSSL TLS |
| protection | Native trust boundary、WASM capability boundary |

xv6 的 process/ring3/syscall/fork/exec 不会机械移植；ppos 借鉴的是清晰的 boot/trap/allocator/locking/FS/test 结构。

### Unikernel 与 Library OS 主线

| 参考 | 吸收的思想 | 明确不照搬 |
|---|---|---|
| [MIT Exokernel](https://pdos.csail.mit.edu/archive/exo/) | 机制与策略分离、应用/库控制高级抽象 | 多租户硬件安全复用 |
| [Drawbridge](https://www.microsoft.com/en-us/research/project/drawbridge/) | 小型稳定 Host ABI、Library OS、应用容器思维 | Windows ABI 与 picoprocess 实现 |
| [Nanos](https://github.com/nanovms/nanos) | 单一应用目标、专用 VM image | Linux binary compatibility 与云平台全套 |
| `third_party/eggos/` | 单地址空间 ring0、协程、网络、VFS、解释器 | Go runtime、GC、GUI |
| `xv6-public-xv6-rev11/` | x86 boot/trap/allocator/console/FS/test | Unix process model |
| `xv6-riscv-xv6-riscv-rev5/` | 现代 xv6 结构、virtio、trap/lock/FS 教材映射 | RISC-V/多核路线 |

参考源码只用于理解和简化移植，不直接修改第三方目录。

## 3. 当前能力

### Platform 与 Kernel

- Multiboot v1 两阶段启动，32 位壳进入 x86-64 long mode；
- 0..4GiB 的 2MiB page identity mapping；
- VGA text、UART serial；
- IDT、8259 PIC、PIT 100Hz、PS/2 keyboard；
- `kmalloc/kfree` free-list allocator；
- `atomic_xchg` spinlock；
- 两任务协作式 context switch demo。

### Library OS Services

- 内存文件系统和 shell script；
- e1000、ARP、IPv4、UDP、DNS；
- uIP 1.0 TCP glue；
- HTTP/1.x client；
- BearSSL TLS 1.2 glue；
- JSON extraction/escaping；
- ppdb SQL/KV/Doc/index/transaction/persistence API；
- MCP tools 与 DeepSeek Agent；
- CLI text browser。

### Applications

- shell；
- browser；
- Agent / `db ask`；
- ppdb shell/MCP interface；
- 最小 WASM loader/interpreter/WASI `fd_write`。

当前 WASM 只能视为 **trusted demo bytecode**：尚未完成完整 validation、linear-memory bounds、operand/local bounds、trap 和 instruction fuel，不能作为不可信应用的安全沙箱。

## 4. pplang v0.3 实现基线

ppos 后续自研代码统一使用 pplang v0.3，不再保留旧语言写法作为新代码模板：

- `[N]T` 数组；
- `u8/u16/u32/u64` 与显式收窄；
- 64 位 pointer/address 通道；
- `str = {address,len}` 与 slice；
- struct、tuple、sum type 和穷尽 `switch`；
- 函数指针与 pointer receiver；
- Ada 式显式泛型；需要的操作能力通过普通函数指针参数显式传入；
- `defer` 与显式 allocator。

优先用类型表达状态和边界：`TaskState`、`KeyEvent`、`AppKind`、`Result` 使用 enum；地址和 stack pointer 使用 `u64`/pointer，不再用 `int` 充当通用指针槽；buffer API 必须显式携带长度或容量。

不为接入某个 C 库新增 pplang 语法。底层硬件能力继续通过 compiler builtin、少量汇编和 C glue 提供。

## 5. Native App Model

Native App 不是 Library。Library OS services 是库；Native App 是静态链接进 image 的程序模块：

```text
Native App
  = descriptor
  + entry function
  + coroutine execution context
  + required capabilities
  + linked library dependencies
```

R3-1/R3-2 descriptor 与 context（R3-3 task runtime 已完成）：

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

R3-1 已删除按注册顺序 hardcode ID 的 `app_dispatch`；R3-2 已升级为 context entry，并将 shell source 复制到每 app owned args。R4 再提供真实 terminal handle；此前 `terminal=0` 明确表示 unavailable。

R3-3 提供 8 槽 cooperative task table，使用 `Unused/Runnable/Waiting/Dead(exit_code)` 状态、allocator-owned 独立栈、entry return trampoline、round-robin yield、event wake 和 `u64` timer deadline。IRQ 不直接调度；R4 将通过 input event queue 把 IRQ 事件交给 cooperative runtime。

R3-4 已将 task 与 App lifecycle 接通：`AppState` 记录 registered/running/exited/failed，typed wait 将 runtime failure 与任意 App exit code 分开；task 0 只作 supervisor，shell、browser、Agent、SQL 与 db frontend 都使用 owned context 和独立栈。`ds/browse/sql/db` 快捷命令只是同一 App Runtime 的前台入口。

Native App 与内核共享地址空间，capability 主要是接口纪律和审计信息，不是硬件安全隔离。Native App panic 或 memory corruption 仍可能破坏整个 image。

## 6. WASM App Model

WASM 用于动态安装、低信任和第三方小程序：

```text
WASM App
  = .wasm file
  + manifest
  + private linear memory
  + instruction budget
  + capability-limited imports
```

目标 Host ABI 只暴露 handle/offset/length，不暴露 kernel raw address：

```text
pp.console.write
pp.clock.now
pp.fs.open/read/write
pp.net.http
pp.db.sql/kv/doc
```

WASM 成为应用边界前必须完成：

- section/type/function/import validation；
- operand stack、local、call depth 边界；
- linear-memory load/store bounds；
- trap 与 app-local failure；
- instruction fuel/timeout；
- capability-filtered imports；
- malformed module regression corpus。

若自研解释器的正确性或维护成本超过课程价值，可改用成熟 freestanding C WASM runtime，仍通过相同 Host ABI 接入。

## 7. Text Workspace

ppos 不规划 framebuffer GUI；规划一个借鉴 tmux 的 **Text Workspace**：

```text
Workspace
  ├─ Window
  │    ├─ Pane -> shell task
  │    └─ Pane -> log task
  └─ Window
       ├─ Pane -> agent task
       └─ Pane -> ppdb/WASM task
```

它是 App Runtime 之上的策略组件，不属于底层 kernel。目标层次：

```text
Text Workspace
  -> App Runtime
  -> Virtual Terminal Service
  -> VGA text / Serial ANSI renderer
  -> keyboard/timer/task kernel mechanisms
```

### Virtual Terminal

每个 terminal 拥有固定大小 cell buffer、cursor、scrollback ring、dirty rows 和 input queue。kernel/interrupt 日志写入 log ring，由 Log Pane 展示；只有 renderer 正常更新物理 VGA/serial，panic 路径可以直接接管 console。

### Pane 与 Layout

```text
Pane = Rect + Terminal + AppTask + InputQueue + Status

Layout = Leaf(pane)
       | Horizontal(left, right, ratio)
       | Vertical(top, bottom, ratio)
```

首版支持：最多 4 windows、每 window 最多 4 panes、水平/垂直 split、focus、close、fullscreen、固定 scrollback、status bar、system log pane。

先提供可测试命令：

```text
ws new
ws split h|v
ws focus <id>
ws run <app>
ws close
```

再加入 tmux 风格 prefix 快捷键。键盘驱动要先从 ASCII 升级为带 Ctrl/Alt/arrow/function key 的 `KeyEvent`。

Native App 的 terminal API 与 WASM `fd_write` 最终汇入同一个 pane，因此 shell、Agent、browser、ppdb 和 WASM 可以共用工作区。

## 8. 外置 C 库与胶水模式

系统课程的核心机制用 pplang v0.3 手写；不属于教学主线、标准复杂且已有成熟实现的组件允许外置。

### 保持现状

- TCP：uIP 1.0 静态库 + `uip_glue.c`；
- TLS：BearSSL 0.6 静态库 + `tls_glue.c`；
- x86-64 boot/context/interrupt：最小 assembly glue；
- freestanding libc 缺口：`boot/libc.c`。

TLS/SSL 本轮不重写。现有 BearSSL known-key pin、pump loop 和 uIP 集成保持工作状态；安全模型和 key/entropy 改进另列任务，不用自研密码学替代。

### 允许外置的判断标准

同时满足以下条件时优先复用成熟 C 包：

1. 组件不是本阶段要学习/验证的核心机制；
2. 协议、格式或安全状态机复杂，手写错误风险高；
3. 有可裁剪、可交叉编译、无动态 OS 依赖的实现；
4. 能通过小型稳定 ABI 隔离；
5. license 和源码来源清楚；
6. 能在 QEMU/host 上建立回归测试。

候选类型包括压缩、图像/文本解析、成熟 WASM runtime、block filesystem、其他密码/协议组件。是否外置按任务逐项决定，不把“能找到库”当成默认引入理由。

### 统一接入方式

```text
upstream C source (read-only)
  -> freestanding cross-compile .a
  -> handwritten *_glue.c
  -> narrow extern declarations
  -> pplang wrapper with typed API
  -> QEMU integration tests
```

ABI 只传固定宽度整数、raw pointer + explicit length、POD struct 和 error code。所有权、buffer capacity、callback lifetime 和 thread/reentrancy 假设必须写在 wrapper 旁。第三方源码保持只读，适配与修复放在 glue/wrapper；不能为某个库临时增加语言特性。

## 9. Image Model

开发镜像可以包含完整诊断和全部 App：

```text
ppos-workspace.elf
  = kernel + libOS + Text Workspace
  + shell + logs + agent + browser + ppdb + WASM
```

部署镜像按 primary app 裁剪：

```text
ppos-agent.elf = kernel + libOS + Workspace + agent + ppdb + MCP
ppos-db.elf    = kernel + libOS + Workspace + ppdb + management shell
```

这吸收 Nanos 的专用 image 思想，但允许同一 trust domain 内存在多个 library module 和 cooperative tasks。完整 manifest/build profile 属于后续工具链工作，不在本轮实现。

## 10. 实施路线

### PPOS-R0：事实与文档对齐

- README、roadmap、app-model 与当前代码对齐；
- 建立 Exokernel/Drawbridge/Nanos/eggos/xv6 参考台账；
- 清理已完成但仍显示未完成的旧任务；
- 明确 Native trusted、WASM 当前 trusted demo、TLS known-key 的边界。

### PPOS-R1：Kernel Reliability

- exception stubs、vector/error/RIP/CR2 `TrapFrame`、panic；
- 64 位 coroutine stack/context/function pointer；
- Multiboot memory map 与中央 reserved-region map；
- allocator bounds、OOM、double-free 检查、相邻块合并；
- QEMU serial regression runner；
- stack alignment、interrupt context、kernel section W^X/NX 审计。

### PPOS-R2：Library OS Boundary

- 拆分 `kernel.pp` 中的 boot mechanism 与 shell/app policy（R2-1 已完成）；
- typed console/task/fs/net/tls/db service API（R2-2 已完成）；
- bounded buffer/writer API，清理固定地址跨模块共享（R2-3 已完成）；
- 8KiB kernel log ring、Log Pane cursor 输入与 panic raw console（R2-4 已完成）；
- C glue ABI/ownership/capacity/reentrancy 合同与目标机回归（R2-5 已完成，见 `docs/c-glue-contract.md`）。

### PPOS-R3：Native App Runtime

- `AppDescriptor` + function-pointer entry（R3-1 已完成）；
- `AppContext` + owned args，不读取 shell 固定地址（R3-2 已完成）；
- task table：Runnable/Waiting/Dead（R3-3 已完成）；
- 通用 coroutine stack、return trampoline、yield、wait event、timer deadline 与 reap（R3-3 已完成）；
- shell/browser/agent/ppdb 迁移为真正 Native App（R3-4 已完成）；
- capability service gate 与“审计纪律、非安全隔离”收口（R3-5）。

### PPOS-R4：Text Workspace

- `KeyEvent` 与 keyboard modifier/arrow 支持；
- Virtual Terminal、cell buffer、scrollback、input queue；
- VGA text 与 serial ANSI 双 renderer；
- window/pane/layout/focus/status；
- shell/log/agent/ppdb/browser pane；
- workspace QEMU interaction tests。

### PPOS-R5：WASM App Runtime

- validator、bounds、trap、fuel；
- capability Host ABI；
- WASI `fd_write` 接入 pane terminal；
- FS 中 `.wasm + manifest` 安装/运行；
- malformed/untrusted module tests；
- 自研路线失控时替换为外置 freestanding C runtime。

### PPOS-R6：Agent Appliance 与持久化

- Agent + ppdb + MCP primary image；
- bounded Agent/JSON/MCP buffers；
- entropy、known-key pin 更新和 secret boundary；
- QEMU block device + block-backed persistence；
- GRUB image、VGA/serial 双输出、T430 部署；
- ARM64 继续搁置。

执行顺序固定为 `R0 -> R1 -> R2 -> R3 -> R4 -> R5 -> R6`。在 R1/R2 完成前不继续堆叠新的上层功能。

## 11. 验证标准

每个阶段至少满足：

- 当前 pplc `pp os` 全量编译；
- QEMU boot ready marker；
- exception/panic 不 triple-fault；
- serial golden + timeout；
- allocator/task/terminal/WASM 边界测试；
- ppdb host tests 不回归；
- uIP/BearSSL/Agent 现有链路保持；
- freestanding C library 有独立 glue contract test。

目标命令：

```bash
cd pplc && cargo build
cd ../ppos && make
make run
# ELF permissions + smoke + exception + allocator
make test
# 也可单独运行
make test-permissions
make test-exception
make test-allocator
```

## 12. 明确边界

近期不做：

- Unix process、fork/exec、完整 POSIX syscall；
- 多用户和远程 shell；
- SMP/多核；
- framebuffer GUI、mouse、floating windows；
- 完整 VT100/PTY；
- 自研 TLS/密码算法；
- ARM64 target；
- 完整 package manager。

计划做的是 Text Workspace，不是图形 GUI。动态程序通过 WASM/manifest/FS；Native App 通过静态 image profile。系统首先追求机制清晰、边界可信、可在 QEMU 与 x86-64 裸机复现。

## 13. 当前构建

依赖当前 pplc、LLVM 18、x86_64 ELF binutils、QEMU，以及已准备的 BearSSL/uIP 静态库：

```bash
cd pplc
cargo build

cd ../ppos
make
make run
```

产物 `kernel.elf` 是两阶段 Multiboot x86-64 image。`make clean` 只清理构建产物；`third_party/` 和参考仓库不参与修改。
