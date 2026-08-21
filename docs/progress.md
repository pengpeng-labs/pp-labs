# 开发进度实录（截至 2026-08）

> 本文档如实记录当前实际开发进度、遇到的困难与卡点，供协同开发参考。
> 任务台账以 docs/roadmap.md 为准；本文是"实际状态 + 困难"的补充记录。

---

## 1. 总体状态

网络栈重构已收尾：**uIP 1.0 胶水端到端打通**（DNS → TCP → TLS → HTTPS → DeepSeek 工具调用，QEMU slirp 实测）。
pp-db P15-1 收尾、语言三层演进（L1/L2/L3）、pplang v0.2 语义收口与 v0.3 显式泛型均已完成。
ppos 已完成架构闭合 R0 与 Kernel Reliability R1：后续以 pplang v0.3 按 `Library OS → App Runtime → Text Workspace` 收口；uIP/BearSSL 保持外置 C 静态库 + glue，不重写 TLS/密码算法。

| 线 | 状态 | 卡点 |
|---|---|---|
| 语言线（pp-lang 编译器） | ✅ 核心完成 | 无（地址模型 64 位化已解决） |
| OS 线（pp-os） | 🟡 功能链路齐全，R0/R1 完成 | R2 拆分 Kernel mechanism 与 Library OS policy |
| 数据库线（pp-db） | ✅ P14~P16 全完成并收尾 | 无 |
| 裸机线（T430/RPi4） | 🟢 刚启动（B-0/B-1 完成） | 等 db ask 收尾后切入 |

---

## 2. 各线实际进度

### 2.1 语言线（pp-lang）— 完成

- 编译器：lexer/parser/AST/mono/sema/codegen（LLVM IR，inkwell）7 个 Rust 源文件
- 命令：`pp ir / run / obj / os / build` 全可用
- 语言能力：let/while/if/struct/enum+switch/显式泛型/import/extern/数组/指针/协程/volatile/u64
- **方案B（地址模型 64 位化）已完成**：`ptr_to_int`→U64、调用/返回点 coerce、`volatile_load64/store64`、`&func` 去截断；宿主机静态数据 >4GB 无截断
- **spec §7 已知编译器问题**：✅ 已全部修复（同名函数重定义报错、variadic extern `...` 语法、数组字面量）
- **pplang v0.2**：小型 sema + 词法作用域、严格 bool、无符号运算、str/FFI 边界与切片检查、指针接收者、受限 tuple
- **v0.2 Sum Type**：`enum` 零/单 payload + 精简 `switch` 单层解构；重复分支、payload 形状、通配顺序与穷尽性均由 sema 检查；LLVM tag 跳转表落地
- **v0.2 stdlib**：`Buf` 可增长字节缓冲 + `StrMap`（FNV-1a/开放寻址/扩容/owned key-value）；编译器黑盒测试 23 项全绿
- **pplang v0.3**：Ada 式显式泛型函数/struct/enum；函数指针表达能力约束；AST 单态化、实例去重与递归膨胀检查；`sizeof[T]`/`alignof[T]`
- **v0.3 stdlib**：`Vec[T]` 用具体元素尺寸分配与扩容，`int`/`u8` 双实例验证；编译器黑盒测试 36 项全绿
- **v0.3 教程**：Starlight 四课程门户 + pplang 理论与设计、pplang Book、Language Reference 完成；pplc 独立教程完成（设计与资料地图、15 章 Book、源码参考），并以“教材模型 → pp 规则推导 → Rust/LLVM 映射 → 反例实验”重写：覆盖正规语言/DFA、CFG 文法、类型判断、F/I/E、替换与单态化、三地址码/CFG/SSA、布局/ABI/链接及综合实验；10 个独立 `.pp` 示例纳入编译检查；ppdb 教程完成，ppos 教程待项目收尾
- **v0.3 定版审计补漏**：规范移除实现不存在的字符字面量；修复字符串常量经 C API 遇 NUL 截断、`x in str` 按旧 NUL 指针扫描的问题，统一按完整 bytes + `{ptr,len}` 语义并新增黑盒回归

### 2.2 OS 线（pp-os）— 功能齐全，uIP 网络栈打通

已完成并验证：
- 引导（multiboot v1 → 长模式）、IDT/中断、PIT 100Hz、PS/2 键盘、VGA、串口
- 内存 FS（16 文件，128KB 池）、shell、协程、app 模型、MCP、WASM 运行时
- e1000 驱动（QEMU 82540EM）
- TLS：**BearSSL 0.6 胶水**（交叉编译 .a + extern + tls_glue.c）
- agent：DeepSeek 对话 + 工具调用（ls/sql/kv/doc）
- **uIP 1.0 胶水**：手写 TCP 已归档，`net.pp`/`tls.pp` 切到 `uip_glue_*`，**端到端验证通过**
  （抓包证实 ARP/DNS/TCP 三次握手/TLS 握手/HTTPS POST/DeepSeek tool_call 全链路正确）

架构闭合已启动（权威任务见 `docs/roadmap.md` Phase 21，设计见 `ppos/README.md`）：
- R0 ✅：明确教学型 x86-64 unikernel 定位、Native/WASM App 边界、tmux 风格 Text Workspace 和参考项目取舍；完成 v0.3 App Model 与固定内存/模块/glue/安全边界地图
- 自研机制继续使用 pplang v0.3；复杂且非教学主线的组件允许复用成熟 freestanding C 包，经 `.a + glue + extern + typed wrapper` 接入
- TCP/TLS 保持现有 uIP 1.0/BearSSL 0.6 胶水，不以自研协议栈或密码算法替换
- R1-1 ✅：0~31 CPU exception 独立 stub、统一 error frame、pplang v0.3 `TrapFrame`、vector/error/RIP/CR2 panic 输出与 halt；`make test-exception` 的 #UD QEMU 回归通过
- R1-2 ✅：coroutine `rsp` 使用 `u64` + load/store64；App/MCP 地址表和 pointer 参数改为 `u64`；e1000 MMIO/DMA 支持 64 位 BAR、descriptor 和 ring address high/low
- R1-3 ✅：boot32→entry64→`kmain` 保留 Multiboot magic/info；解析变长 mmap entry；中央表登记 firmware region、page table、boot/kernel image、Multiboot 数据与 fixed arena；linker symbol 校验 kernel/stack/fixed/heap 边界。QEMU 实测 usable end `0x07fe0000`、12 regions
- R1-4 ✅：allocator 全面改为 `u64`；32-byte header 记录 next/size/magic/state/canary；heap 上限来自 Multiboot usable region 并受 4GiB identity map 限制；OOM 返回 null；非法/未对齐/double-free 返回 false；free payload `0xDD` poison；地址序插入并向前/向后合并。`make test-allocator` 覆盖对齐、poison、非法释放、合并复用和 OOM
- 过程中发现 `0x100000000 as u64` 会在 cast 前按 32 位截断；ppos 改用 `(0xFFFFFFFF as u64) + 1` 构造 4GiB 边界，避免静默截断
- R1-5 ✅：删除默认启动期在线 `db ask` autotest，正常镜像初始化后输出 `PPOS READY` 并立即进入 shell；统一 `run_qemu_test.sh` 管理 QEMU 生命周期、serial log、timeout、提前退出、unexpected panic 与重复启动/triple-fault；smoke 模式经 monitor 注入真实 PS/2 `help`/`app list`，exception/allocator 共用相同 runner；`make test` 三模式全绿
- R1-6 ✅：IRQ stub 保存/恢复全部 GPR 与 XMM0~15，并用 software IRQ 自检寄存器保持；检查 SysV 调用栈对齐；2~4MiB kernel 映射改为 4KiB PTE，text/rodata/data 分别为 RX/R/RW+NX，启用 `CR0.WP` 与 `EFER.NXE`；内外层 ELF 使用独立 PHDR 和 noexecstack，`make test-permissions` 拒绝 W+X LOAD/GNU stack
- R1-6 调试中发现 QEMU Multiboot info 位于 `0x9500`，最初选择 `0x9000` 作为 kernel PT 会覆盖 firmware 数据；最终复用页表布局中的空闲 `0x8000..0x8fff`，并由完整 QEMU 回归验证
- PPOS-R1 已完成；下一项是 R2-1：拆分 `kernel.pp` 的 boot/memory/task/driver mechanism 与 shell/agent/db policy
- R2-1 ✅：`kernel.pp` 从 819 行收缩为 103 行 composition root，只保留 extern、imports 与 `kmain`；新增 `kernel_console.pp`（serial/VGA/panic/TrapFrame）、`kernel_memory.pp`（Multiboot region/allocator）、`kernel_irq.pp`（PIC/PIT/PS2）、`kernel_task.pp`（context switch）和 `kernel_shell.pp`（shell/agent/db policy）。Makefile 显式追踪所有模块，完整 `make test` 全绿
- 当前主线进入 R2-2：建立 typed console/task/fs/net/tls/db service API；优先替换 shell 直读 `0x400000` keyboard ring 和 task `0x500000` 固定 context slot
- R2-2 第一批 ✅：`kernel_irq.pp` 用 `input_read()` 封装 IRQ-owned keyboard ring，shell 不再读取 `kb_r/kb_w/0x400000`；`kernel_task.pp` 使用私有 `[2]u64` context table，并提供 `task_create_secondary/task_yield`，bootstrap/shell 不再读写 `0x500000` 固定 slots。真实 PS/2 注入与 cooperative switch 经 `make test` 验证
- R2-2 第二批 ✅：console 提供按 pplang `{ptr,len}` 输出的 `console_write/console_write_bytes/console_putc`，ppos 自有模块完成迁移；FS 提供 `FileHandle` 与 `file_*` facade，shell/agent 不再使用裸 slot；新增 `ServiceBytes {data,len,ok}`，HTTP/HTTPS 返回 service-owned view，browser/agent 不再知道 `0x650000/0x670000` 响应地址。同步修复 uIP C callback `pp_dbg(const char*)` 被错误声明成 pplang `str` 的 ABI 债务
- R2-2 第三批 ✅：新增 ppos-only `db_service.pp`，用 `DbTableHandle`、`ServiceBytes` 和 bounded SQL output facade 包装独立 ppdb；shell/MCP/Agent 已无 ppdb 原始 API 调用。ppdb native 的 golden/持久化/容量边界/SQL/损坏镜像测试与 ppos `make test` 均全绿
- PPOS-R2-2 已完成：单物理终端阶段不制造虚假的 `id=0` console handle；真正的 Virtual Terminal handle 属于 R4，Native App 参数所有权由 R3 `AppContext` 解决。下一项为 R2-3 bounded buffer/writer API
- R2-3 第一批 ✅：新增 freestanding `BoundedWriter {data,len,cap,failed}` 与启动 canary 自检；单次 append 预检整体空间，失败后锁定且不继续发送。HTTP/TLS request 明确 2048/4096B 上限，HTTP response 限制 64KiB；Agent body/user/history/tool-message 分别限制 4096/2048/2048/2048B；JSON escape、chunked decode、字段提取均使用显式 source/output bounds
- 已删除现役代码中的 `agent_append/json_escape/req_append/str_len` 无界模板；第一批完成时仅余 MCP JSON-RPC response/tool-result builder
- R2-3 第二批 ✅：MCP API 全链路传递 capacity；SQL 256B、key/value/doc 128B、op 64B，method/name 修复 NUL off-by-one；tool result 使用独立 3072B 静态槽，shell request/response 使用独立 4096B 槽，消除 `0x401200` result 与 `0x401300` SQL 参数重叠。JSON-RPC success/error/tools-list/tools-call 全部使用 `BoundedWriter`
- PPOS-R2-3 已完成：smoke 真实注入 `mcp list` 并验证完整 `"result":{"tools"` JSON；permissions/smoke/exception/allocator 全绿。下一项为 R2-4 kernel log ring + Log Pane 输入源

- PPOS-R2-4 ✅：`kernel_console.pp` 增加 8KiB 覆盖式 log ring、单调序号 `KernelLogCursor` 与 overwritten-byte `lost` 统计；`kernel_log_read` 是未来 Log Pane 的增量输入边界。console critical section 通过 `irq_save_disable/irq_restore` 保持调用者 IF 状态，允许 IRQ 输出而不死锁；正常输出当前同时写 ring 与 serial，R4 renderer 接管后移除物理镜像
- panic/exception 先 `cli` 并切换独占态，绕过普通 console、ring 与 spinlock 直接写 raw UART；early #UD exception 回归覆盖普通启动输出前的 panic。启动 selftest 覆盖顺序读取、8KiB wrap 与 lost；smoke 的 `log` 命令确认快照真实回放 `PPOS READY`。完整 `make test` 全绿，下一项为 R2-5 C glue contract
- PPOS-R2-5 ✅：新增 `boot/pp_glue.h` 和 `docs/c-glue-contract.md`，固定 pp↔C 的 u64 pointer/int32 length-capacity ABI、错误码、同步借用 callback、poll non-reentrancy、BearSSL arena 与单会话 known-key ownership。BearSSL extern 地址和 pointer 返回统一为 `u64`
- glue 审计修复实际数据债务：TCP pending 从“部分复制”改为 all-or-nothing；TLS 只在完整 record accepted 后 ack；RX ring 支持跨尾部复制并在容量不足时显式失败；NIC callback 新增 capacity，过大 descriptor 整帧拒绝；DNS 查询/发送不再静默截断；无 NIC 不访问未初始化 ring
- `make test-glue-contract` 以 `-Wall -Wextra -Werror` 交叉编译并核对 ABI 符号；QEMU 启动自测覆盖 pending 失败原子性、错误码、BearSSL 实际类型容量和 TLS session 重入/恢复，smoke 验证 `GLUE CONTRACT PASS`。完整 `make test` 全绿。PPOS-R2 Library OS Boundary 全部完成，主线进入 R3 Native App Runtime
- PPOS-R3-1 ✅：`app.pp` 改为 `[8]AppDescriptor` registry，descriptor 持有切片 name/description、function-pointer entry、capability mask 和 stack size；删除注册顺序与分支顺序耦合的 `app_dispatch(id)`，间接调用统一返回 exit code；R3-2 已将初版 `fn() -> int` 升级为 `fn(*AppContext) -> int`
- browse/ds/sql/db 使用显式 wrapper entry 和 image profile 元数据；list/help 输出 capability 名称及 stack size，注册溢出/非法 stack 被拒绝。启动 selftest 验证 descriptor 字段与函数指针调用，smoke 真实执行 `app run sql` 并验证 `app exit=0`；完整 `make test` 全绿。下一项为 R3-2 AppContext 与参数所有权
- PPOS-R3-2 ✅：新增 `AppContext {terminal,args,capabilities}`，每个 registry slot 拥有独立 256B args 和 context；runtime 在调用前全量复制 shell source、补 NUL 但以 `str` 真实长度传递，capabilities 只能来自 descriptor。`terminal=0` 表示 R4 前无 terminal handle，不冒充物理 console handle
- descriptor entry 统一升级为 `fn(*AppContext) -> int`；browse/ds/sql 只读 context args，Agent 输入地址同步升为 `u64`；同 app 重入返回 `-2`，超限参数返回 `-3`。启动自测修改原 source 后验证 owned copy 不变，并覆盖 capability 注入、重入和 256B 拒绝；QEMU 验证 `APP CONTEXT PASS`，完整 `make test` 全绿。下一项为 R3-3 task table
- PPOS-R3-3 ✅：`kernel_task.pp` 建立 8 槽 cooperative task table，状态为 `Unused/Runnable/Waiting{event,deadline}/Dead(exit_code)`；每个 task 从 bounded allocator 获得独立且至少 4KiB 的栈，entry 正常返回后统一进入 trampoline 记录 exit code，不会从初始 context 返回到垃圾地址
- scheduler 使用 round-robin runnable 扫描；`task_wait` 同时支持 event-only、timer-only 和 event-or-timeout，PIT deadline/tick 使用 `u64`；`task_wake_event` 只允许 cooperative context 调用，IRQ 到 task 的队列边界留给 R4。启动自测覆盖 event wake、2 tick timeout、`Dead(37)` 与 stack reap；QEMU smoke 验证 `TASK RUNTIME PASS`，完整 `make test` 全绿。下一项为 R3-4 Native App 生命周期迁移
- PPOS-R3-4 ✅：task entry 增加不透明 `u64` argument，App Runtime 以 descriptor id 启动统一 trampoline；新增 `AppState {Registered,Running(task_id),Exited(code),Failed(code)}` 和 typed `AppWaitResult`，start error 与任意正负 App exit code 分离，前台 wait 后回收 task stack 但保留最终状态供 `app list` 审计
- bootstrap task 0 现为 scheduler supervisor；shell 本身注册为 Native App 并使用 32KiB 独立栈。browse、ds、sql、db 及其 shell 快捷命令全部进入同一 start/wait/exit/reap 路径；db 子命令只读 owned `AppContext.args`，token/result 改为模块私有 scratch，不再借用 shell `0x400200/0x400300`
- 启动 selftest 覆盖真实 App task、重复启动、正常/失败状态和 reap，QEMU 验证 `APP LIFECYCLE PASS`、真实 PS/2 shell、SQL `state=exited:0`，并跨两次 db App 启动完成 `db put/get`。glue/permissions/smoke/exception/allocator 全绿；下一项为 R3-5 capability service gate 与安全边界收口

uIP 胶水进度（已收尾）：
| 步骤 | 状态 |
|---|---|
| uIP 原版 + 裁剪版独立编译 | ✅ 通过（gcc/macOS） |
| uIP 核心 TCP 状态机纯函数级测试（test_uip.c） | ✅ 完成（T1/T2/T3 PASS；T4/T5 是测试程序字节序 bug，uIP 本身正确，未提交仓库） |
| uip_glue.c 封装 net_* 接口 | ✅ 完成 |
| pp-os 集成（替换手写 TCP） | ✅ 完成（端到端打通） |

uIP 集成期间修复的 6 个 bug（均在 ppos 侧，非 uIP 本身）：
1. `kernel.pp` PIT：`tick_count` 每 10 tick 清零 → `pp_ticks()/100` 恒 0 → uIP periodic 驱动（重传/DNS 发包）永不触发。改为独立 `tick_dot` 打点。
2. `net.pp` `dns_parse`：answer 偏移 `i+12+rdlen` 应为 `i+10+rdlen`，否则跳过首个 A 记录。
3. `uip_glue.c`：`uip_glue_init` 未设 `uip_setdraddr`/`uip_setnetmask` → 跨网段直接 ARP 目标 IP 而非网关，SYN 发不出。
4. `uip_glue.c` DNS：`uip_send` 后查 `uip_len` 判断成功是错的（该值 appcall 返回后才生效）→ 改收到响应才清 pending。
5. `uip_glue.c` TCP 发送：`uip_glue_send` 覆盖式缓冲，TLS 连续 3 记录（CKE+CCS+Finished）只发最后一个 → 服务器 `unexpected_message`。改累积。
6. `uip_glue.c` TCP 发送：累积数据 > MSS 时 `uip_send` 溢出 `uip_buf` → 按 MSS 分片。

### 2.3 数据库线（pp-db）— P14 全完成

已完成并验证：
- P14-1~7 ✅：存储内核（页式堆表）/SQL 解析/执行器/KV/Doc/二进制持久化/宿主机双宿主
- **独立分发（D-1~D-3）✅**：CLI（cli.pp）+ 真实文件持久化 + 测试套件（golden + 跨进程），全 PASS
- P15-2 ✅：MCP 工具 sql/kv/doc

已完成：
- **P15-1 db ask**：网络链路 + SQL `SELECT *` + 多轮 TLS 连接健壮性全打通（DNS→TCP→TLS→HTTPS→DeepSeek tool_call 全通）。
- **pp-db 稳定化 S1~S5**：修复第 128 页越界和固定槽边界；SQL parser 移除 pp-os 固定地址并用 v0.3 Sum Type 表达 statement/value/比较；PDB4 保存真实列名；project/WHERE/UPDATE 按名称执行；native CLI、pp-os、MCP 共用 parser/executor；`DbScan` 支持嵌套扫描；DELETE 即时回收页内空间；load 两遍预检且失败不污染现有状态。
- **P15-3a**：`SELECT ... TO JSON` 完成，复用真实投影和 WHERE，CLI/MCP 共用 JSON 输出路径。
- **P15-3b/P16**：稳定 row ID + 直接定位、有序单列 INT 索引、等值/范围 planner、PDB4 索引定义、CRUD 重建；BEGIN/COMMIT/ROLLBACK before-image UNDO；Rust 语义 oracle 完成；Starlight ppdb 教程重构为设计定位/理论地图 + 15 章 Book + 实现参考，以数据库模型 → invariant → pplang 实现 → 实验贯穿存储、查询、多模型、Agent 与双宿主。
- **回归**：host golden、跨进程 PDB4+索引往返、第 128 页、KV/Doc 满容量、多字符串/乱序 INSERT、非首列条件与更新、索引范围计划/维护、RDB+KV+Doc 事务、嵌套扫描、200 轮删除复用、损坏镜像均通过；Rust golden、Starlight build、pp-os 两阶段构建通过。

### 2.4 裸机线 — 刚启动

- B-0/B-1 ✅：编译器地址模型 64 位化 + 内核回归
- T-1/T-2（T430）未开始；A-1~A-5（RPi4/ARM64）已明确搁置

---

## 3. 卡点详解（均已解决）

### 卡点 1：uIP 测试 T4/T5（✅ 已解决）

- **现象**：test_uip.c 的 T4（数据接收）未触发 NEWDATA
- **根因定位**：uIP 内部 `lport` 是网络序 u16 在 LE 机器的内存表示（如 260），
  测试程序 feed 帧的端口字节序与之一致性处理有误
- **性质**：**测试程序 bug，不是 uIP 的问题**——uIP 的握手/发送已证明正确
- **结局**：test_uip.c 未提交仓库（临时测试），直接跳过纯函数测试、写 `uip_glue.c` 并集成，
  在 QEMU slirp 里端到端验证通过（见 §2.2 的 6 个 bug 修复记录）

### 卡点 2：手写 TCP 的 TLS 大响应（已被 uIP 方案取代）

- 历史：手写 TCP 在 QEMU slirp 下 TLS 大响应（~1.5KB）接收不可靠
- 已修 5 个边界：TCP data offset、CLOSED 残留读取、FIN 检测、seq 连续性校验、tls_init 状态重置
- 仍存在：多轮工具调用（连续 3 次 TLS 连接）时偶发握手失败（BAD_SIGNATURE，残留帧混入）
- **决策**：不再深挖手写 TCP，改用 uIP 1.0 胶水（成熟 TCP 状态机）——已落地并打通

### 卡点 3：macOS 宿主无法直接测试 uIP 网络（✅ 已解决）

- uIP unix 示例依赖 Linux TAP 设备（/dev/net/tun），macOS 无
- 解决：纯函数级测试（构造帧喂 uip_input，断言输出）→ 最终用 **QEMU slirp + 抓包（filter-dump）** 端到端验证，比纯函数测试更直接

### 卡点 4：db ask 的 SQL 层 + 多轮连接（✅ 已解决）

- **现象 1**：DeepSeek 返回 `SELECT * FROM notes`，pp-db SQL 解析器报 `sql: syntax error`（`*` 通配符/星号列未支持）
- **现象 2**：第三轮工具调用 `no https response`（多轮 TLS 连接偶发失败）
- **归属**：均非网络栈（uIP 链路已通），属 pp-db SQL 解析器与 agent 多轮连接管理
- **结局**：① `db_sql_parse.pp` 解析 `*`，稳定化阶段后由 `db_sql_exec.pp` 展开表目录中的真实列名；② `uip_glue.c` 每轮 connect 重置接收环形缓冲 `rxbuf_head/tail/full`（跨轮残留污染下一轮 TLS 记录 + 缓冲末尾 space 截断大响应）

---

## 4. 关键决策记录

| 决策 | 内容 | 理由 |
|---|---|---|
| 网络栈换 uIP | 手写 TCP → uIP 1.0 胶水（.a + extern + glue） | 手写 TCP 边界无穷，uIP 成熟 |
| 胶水模式 | BearSSL 同款：交叉编译 .a + extern + C 胶水 | pp-lang 能力足够，不需要新语言特性 |
| net_* 接口层 | 封装 net_connect/send/recv/close/poll | 协议无关，tls.pp 变薄，真机可复用 |
| 方案B 优先 | 编译器地址模型 64 位化先于 pp-db 宿主机 | 宿主机静态 >4GB 是硬前提 |
| db ask 依赖网络 | P15-1 需网络栈稳定才能完整验证 | LLM 多轮调用需要 3 次 TLS 连接 |

---

## 5. 未做事项清单（协同开发候选）

| 优先级 | 事项 | 适合谁 |
|---|---|---|
| 🔴 | PPOS-R3-5 Native capability service gates + boundary audit | 当前主线 |
| 🟡 | PPOS-R4 Text Workspace | R3 完成后推进 |
| 🟢 | ppos 教程（P13-6）与 pplang/pplc 英译（P13-7） | 可并行 |
| 📌 | ~~uIP 集成修复未提交~~（已提交 `4a05108`/`c8ea251`/`7a31bd5`） | 已解决 |

---

## 6. 协同开发建议

1. **uIP 集成修复已提交**（`4a05108`/`c8ea251`/`7a31bd5`）：语言三层演进、db ask 收尾、数组语法迁移均已入库
2. **pp-db 后续任务已清零**；当前切换到 ppos 架构闭合，ARM64 target 继续搁置
3. **单线程任务**：按 PPOS-R0 → R1 → R2 → R3 → R4 → R5 → R6 推进；R1/R2 前不增加上层功能
4. **文档现状**：roadmap.md 是任务台账，ppos/README.md 是 ppos 架构蓝图，baremetal.md 是裸机设计，ppdb.md 是数据库设计
