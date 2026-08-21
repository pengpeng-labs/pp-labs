# ppos Memory, Module and Glue Map

> 状态审计基线：2026-08。本文记录当前事实和迁移目标，不表示现有固定地址已经安全。

## 1. Boot 与地址空间

当前启动链：

```text
GRUB Multiboot v1
  -> boot32.S @ 0x00100000
  -> page tables @ 0x00001000..0x00008fff
  -> identity map 0..4GiB (kernel 2..4MiB uses 4KiB pages)
  -> embedded kernel64 image @ 0x00200000
  -> entry64 -> IDT -> kmain
```

`boot64.S` 提供 16KiB bootstrap stack，IDT 位于 kernel `.bss`。R1-3 已将 Multiboot magic/info 从 boot32 传给 `kmain`，解析变长 mmap entry，并由 linker 导出 kernel/stack 边界。中央 region 表登记 firmware map 与 ppos-owned reserved ranges；R1-4 已让 allocator 使用对应 usable region 的动态上限。R1-6 使用 `0x8000..0x8fff` 的空闲页作为 kernel PT，避免覆盖 QEMU 放在 `0x9500` 的 Multiboot info。

## 2. 固定内存区

| 地址/范围 | 当前 owner | 用途 | 风险/迁移目标 |
|---|---|---|---|
| `0x001000..0x008fff` | boot32 | PML4/PDPT/4×PD + kernel PT | 已纳入 reserved map；不得扩张覆盖 Multiboot info |
| `0x0b8000` | console | VGA text memory | 仅 renderer/panic console 可写 |
| `0x100000` | boot32 | Multiboot 32-bit image | 与 kernel image 合并登记 reserved |
| `0x200000...` | kernel64 | text/rodata/data/bss/stack/IDT | linker start/end 已校验并登记 reserved |
| `0x400000..0x4000ff` | keyboard | IRQ-owned byte ring；shell 仅经 `input_read()` 读取 | R4 改 `KeyEvent` queue |
| `0x400200..0x4002ff` | shell | command line source；R3-2 runtime 启动 App 前复制 | App entry 不读取/保存该地址；R4 改 terminal input |
| `0x400300..0x400fff` | shell/db | shell parser argument/result scratch | App entry 不读取；其他 shell policy 继续迁移 |
| `0x401000..0x401fff` | WASM/shell | trusted module scratch | MCP 已迁出；R5 改 instance-owned memory |
| `0x404000..` | WASM | demo execution scratch | 改 instance-owned memory |
| `0x405000..` | WASM | linear memory base | 加 limit/bounds/instance ownership |
| `0x407000..0x4073ff` | Agent/DB | schema/message scratch | 改 bounded Agent workspace |
| `0x500000..0x500017` | 已释放 | 旧 coroutine saved stack slots | R2-2 已迁入 `kernel_task.pp` 私有静态表 |
| `0x600000...` | e1000/net | DMA/frame scratch | allocator 返回 DMA region并记录容量 |
| `0x630100..0x6308ff` | HTTP service | 2048B bounded request writer | service-owned；溢出拒绝发送 |
| `0x620000..0x6300ff`、`0x630900..0x640fff` | network | packet/DNS/checksum scratch | 后续迁移 network-owned buffers |
| `0x650000...` | HTTP service | response/body buffer | 通过 `ServiceBytes` 暴露，browser 不知道魔法地址 |
| `0x660000..0x66cfff` | BearSSL wrapper | contexts/seed/TLS IO | wrapper-owned arena + capacity contract |
| `0x66d000..0x66dfff` | Agent | 4096B bounded request body | `BoundedWriter`，溢出终止请求 |
| `0x66e000..0x66efff` | HTTPS service | 4096B bounded HTTP request | `BoundedWriter`，溢出拒绝发送 |
| `0x670000..0x670fff` | HTTPS service | TLS 明文响应 | 通过 `ServiceBytes` 暴露，Agent 不知道魔法地址 |
| `0x671000..0x673fff` | Agent | decoded JSON + extracted fields/tool result | decode/extract 有显式上限；field slots 各 256B |
| `0x674000..0x6767ff` | Agent | user/history/tool-message，各 2048B | `BoundedWriter`；溢出终止当前 Agent 调用 |
| `0x1000000...heap_limit` | heap | bounded bump + free-list | 上限来自所在 usable region，并裁剪到 4GiB identity map |

所有范围当前位于 0..4GiB identity map。表中的边界多为源码约定，不是链接器或 allocator 强制的不变量。

## 3. Source Module Map

| 模块 | 当前职责 | 目标层 |
|---|---|---|
| `boot/boot32.S` | Multiboot、页表、long mode | platform boot |
| `boot/boot64.S` | entry、IDT/stubs、context switch | platform/trap/task mechanism |
| `kernel.pp` | composition root、`kmain` 初始化与 bootstrap scheduler supervisor | bootstrap/composition root |
| `kernel_console.pp` | 8KiB log ring/cursor、serial mirror、VGA clear、panic raw UART、TrapFrame 输出 | log service + platform console/trap presentation |
| `kernel_memory.pp` | Multiboot region map、reserved map、bounded allocator | kernel memory mechanism |
| `kernel_irq.pp` | PIC/PIT/PS2、tick、keyboard byte ring | platform IRQ/input driver；R2-2 改 typed input API |
| `kernel_task.pp` | 8 槽 cooperative task table、`u64` entry argument、独立栈、trampoline、event/deadline wait、reap | task mechanism；R3-3/R3-4 完成 |
| `kernel_shell.pp` | shell App、heartbeat、browser/agent/sql/db entries 与 db 私有 command scratch | Native App frontend policy；R3-4 完成 |
| `libos.pp` | `ServiceBytes {data,len,ok}` 等跨 service POD contract | Library OS public contracts |
| `db_service.pp` | `DbTableHandle`、SQL console/buffer、KV/Doc typed facade | ppos Library OS DB boundary |
| `fs.pp` | in-memory file store + typed `FileHandle/file_*` facade | Library OS FS |
| `net.pp` | PCI/e1000、ARP/DNS、uIP callbacks、HTTP | driver + net service 拆分 |
| `tls.pp` | BearSSL/uIP pump、HTTPS | TLS/HTTP service |
| `json.pp` | JSON/chunk helpers | bounded data library |
| `app.pp` | descriptor/context registry、`AppState`、task binding、typed start/wait/reap、reentry guard | Native App Runtime；R3-1~R3-4 完成，R3-5 接 capability gate |
| `browser.pp` | fetch/render policy | Native App + browser library |
| `agent.pp` | LLM/tool loop | Native App + Agent library |
| `mcp.pp` | bounded MCP parser/tool dispatch/JSON-RPC writer | Library OS/Agent service |
| `wasm.pp` | trusted demo parser/interpreter | WASM Runtime |
| `../ppdb/*.pp` | embedded database | Library OS service + Native frontend |

## 4. Assembly/C/Extern Map

### Assembly ABI

| symbol | caller | contract | debt |
|---|---|---|---|
| `load_idt` | `kmain` | build/load 256-entry IDT | exception metadata/panic |
| `switch_context` | scheduler | save old `rsp`, load new `rsp` | `u64` stack pointer；cooperative only，IRQ 不直接切换 |
| `make_context` | scheduler | construct callee-saved frame | R3-3 使用 allocator-owned stack，并以 pplang trampoline 处理 entry return |
| `rdtsc` | TLS wrapper | low 32-bit timestamp | not cryptographic entropy |
| `irq_save_disable/irq_restore` | console service | save RFLAGS, mask IRQ around ring lock, restore caller IF state | x86-only platform ABI；R4 renderer 仍复用 |
| compiler builtins | pplang code | port IO, volatile, hlt/cli/sti | platform-only API |

### C Glue

| boundary | implementation | direction | contract debt |
|---|---|---|---|
| TLS | `boot/tls_glue.c` + BearSSL 0.6 | pplang calls BearSSL wrapper | R2-5 已固化 arena capacity、单 session/known-key ownership；entropy/CA policy 仍受限 |
| TCP | `boot/uip_glue.c` + uIP 1.0 | pplang network callbacks both directions | R2-5 已固化 all-or-nothing send、callback capacity/lifetime、non-reentrancy 与 state reset |
| libc | `boot/libc.c` | BearSSL/uIP dependencies | supported function subset |

BearSSL/uIP 源码和协议实现保持不变。新修复优先进入 glue 或 pplang wrapper，并用 QEMU 端到端回归保护。

完整 ABI、错误码、ownership、capacity、callback 和测试合同见 [`c-glue-contract.md`](c-glue-contract.md)。C 侧声明的唯一来源是 `ppos/boot/pp_glue.h`。

### ABI 规则

- freestanding extern 使用固定宽度整数；地址通道使用 `u64`，不使用 `int`；
- buffer 必须是 `address + length/capacity`；
- C 返回的 pointer 不伪装成 `str`；
- callback 不保存超出约定生命周期的 pplang view；
- glue 不分配未知 ownership 的内存；确需分配时必须提供配对释放函数；
- 所有 error code 在 typed wrapper 转换为 pplang Sum Type。

## 5. 当前安全边界

| 边界 | 当前保证 | 不保证 |
|---|---|---|
| Native App | 静态可信、同一 image、API 约定 | 地址隔离、权限隔离、故障隔离 |
| WASM | 仅运行受信 demo module | 完整 validation、bounds、fuel、安全沙箱 |
| TLS | BearSSL 1.2 + known-key 路径已端到端验证 | 通用 CA store、安全 secret storage、可靠硬件 entropy |
| FS/ppdb | 内存宿主、ppdb API 可用 | ppos 跨重启持久化、权限/加密 |
| C glue | 已有工作链路 | 统一 ownership/capacity/reentrancy 证明 |
| Memory | allocator 服从 Multiboot RAM 上限；kernel text/rodata/data 为 RX/R/RW+NX；CR0.WP/NXE 开启 | guard page、固定 scratch 自动重叠检测、Native App 隔离 |

R1-2 已完成的地址通道：coroutine `rsp`、App/MCP registry 与 pointer 参数、e1000 MMIO BAR、DMA ring/buffer 和 descriptor address。HTTP/TLS/Agent 的固定 scratch arena 仍是 R2 bounded service 的迁移对象。

R1-4 allocator block 使用 32-byte header：`next:u64 / size:u64 / magic:u32 / state:u32 / canary:u64`。allocated/free 状态转换受校验；free payload 写 `0xDD`；空闲块按地址排序并合并。OOM 返回 0，调用方必须检查；元数据损坏触发 kernel panic。

R1-5 测试入口为 `make test`：正常镜像等待 `PPOS READY`，通过 QEMU monitor 注入 PS/2 键盘命令并校验 shell golden；exception 和 allocator 使用专用构建符号，但共用 serial runner。runner 将 unexpected panic、重复启动、QEMU 提前退出和 marker timeout 视为失败。

R1-6 IRQ stub 保存全部 GPR 与 XMM0~15，并通过 software IRQ 检查寄存器保持；bootstrap 调用边界检查 SysV 16-byte stack alignment。kernel 的 2~4MiB 映射使用 4KiB PTE：text 为 RX、rodata 为 R+NX、data/bss/stack 为 RW+NX；`CR0.WP` 让 ring0 同样服从只读页。`make test-permissions` 同时审计 64 位内核和 32 位外层镜像，拒绝 W+X LOAD 与 executable GNU stack。

R2-1 完成源码所有权拆分，但尚未宣称地址隔离：pplang import 当前会扁平展开为一个程序，模块之间仍可访问全局符号。R2-2 已完成 input/task、length-aware console、`FileHandle`、HTTP/HTTPS `ServiceBytes` 与 ppos-only ppdb facade；旧 `serial_*` 只作为嵌入 ppdb 的兼容入口。Buffer capacity 属于 R2-3，App 参数所有权属于 R3，Virtual Terminal handle 属于 R4。

R2-3 引入 `BoundedWriter` 和失败锁定语义，覆盖 HTTP/TLS request、Agent body/history/tool messages、JSON escape/decode/extract 与 MCP JSON-RPC 全链路。MCP 参数和 tool result 已迁入模块私有定长数组，不再共享 `0x401xxx`；shell 使用 4096B request/response，Agent tool result 使用 3072B。溢出返回错误，不发送或消费截断消息。

R2-4 将普通 console 输出写入 8KiB 覆盖式 kernel log ring。`KernelLogCursor.next` 使用单调 `u64` 序号，consumer 落后超过一圈时由 `lost` 报告被覆盖字节；`kernel_log_read(cursor,dst,capacity)` 是 R4 Log Pane 的输入合同。单核 critical section 保存/恢复 RFLAGS.IF，IRQ handler 可以安全走相同 console 路径。当前 R4 尚未实现，普通输出仍同步镜像到 serial；panic/exception 会先屏蔽 IRQ、切换独占态，并绕过 ring/lock 直接写 raw UART。启动 selftest 覆盖顺序、wrap/lost，QEMU smoke 用临时 `log` shell reader 验证实际回放。

R3-3 将旧两槽 context demo 替换为 8 槽 typed task table。task stack 由 allocator 持有，entry return 经 trampoline 转为 `Dead(exit_code)`，由其他 task reap；`Waiting` 可携带 event 与 `u64` PIT deadline。`task_wake_event` 的合同限定在 cooperative context，IRQ 只生产输入事件的边界由 R4 实现。

R3-4 通过 `u64` task argument 将 App descriptor id 交给统一 trampoline。bootstrap task 0 不承载 shell policy；shell、browser、Agent、SQL 和 db frontend 都是独立栈 Native App。App args 由 runtime slot 持有，start error 与 exit code 分通道，reap 后保留 `Exited/Failed` 状态。capability 仍是审计元数据，R3-5 才增加 facade gate，且不会形成地址空间或故障隔离。

## 6. R1/R2 验收出口

R1 完成时：

- exception 输出 vector/error/RIP/CR2 并稳定 halt；
- stack/context/address 保存全为 64 位；
- kernel、page table、fixed arena、DMA 和 heap 均进入 reserved-region map；
- allocator 不越过物理内存且能报告 OOM/非法 free；
- QEMU serial runner 能识别 ready、panic、timeout。
- IRQ 保存 compiler-visible GPR/XMM，kernel section 满足 W^X/NX，ELF 权限可自动审计。

R2 完成时：

- App 不直接访问本表固定 scratch 地址；
- console/fs/net/tls/db 有 typed bounded service API；
- kernel log 与 App terminal 分离；
- 每个 C glue boundary 有 ABI/ownership/capacity/reentrancy 文档和回归测试。
