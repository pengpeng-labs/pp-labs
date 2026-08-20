# 开发进度实录（截至 2026-08）

> 本文档如实记录当前实际开发进度、遇到的困难与卡点，供协同开发参考。
> 任务台账以 docs/roadmap.md 为准（当前 checkbox 104/135；包含被后续阶段覆盖的历史重复项）；本文是"实际状态 + 困难"的补充记录。

---

## 1. 总体状态

网络栈重构已收尾：**uIP 1.0 胶水端到端打通**（DNS → TCP → TLS → HTTPS → DeepSeek 工具调用，QEMU slirp 实测）。
pp-db P15-1 收尾、语言三层演进（L1/L2/L3）、pplang v0.2 语义收口与 v0.3 显式泛型均已完成。

| 线 | 状态 | 卡点 |
|---|---|---|
| 语言线（pp-lang 编译器） | ✅ 核心完成 | 无（地址模型 64 位化已解决） |
| OS 线（pp-os） | ✅ 功能齐全，uIP 网络栈打通 | 无（手写 TCP 已归档） |
| 数据库线（pp-db） | ✅ P14 全完成 + P15-1/P15-2 完成 | 无 |
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
- **v0.3 stdlib**：`Vec[T]` 用具体元素尺寸分配与扩容，`int`/`u8` 双实例验证；编译器黑盒测试 35 项全绿

### 2.2 OS 线（pp-os）— 功能齐全，uIP 网络栈打通

已完成并验证：
- 引导（multiboot v1 → 长模式）、IDT/中断、PIT 100Hz、PS/2 键盘、VGA、串口
- 内存 FS（16 文件，128KB 池）、shell、协程、app 模型、MCP、WASM 运行时
- e1000 驱动（QEMU 82540EM）
- TLS：**BearSSL 0.6 胶水**（交叉编译 .a + extern + tls_glue.c）
- agent：DeepSeek 对话 + 工具调用（ls/sql/kv/doc）
- **uIP 1.0 胶水**：手写 TCP 已归档，`net.pp`/`tls.pp` 切到 `uip_glue_*`，**端到端验证通过**
  （抓包证实 ARP/DNS/TCP 三次握手/TLS 握手/HTTPS POST/DeepSeek tool_call 全链路正确）

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
- **结局**：① `db_sql_parse.pp` 解析 `*` + `db_sql_exec.pp` 展开列占位 c0/c1/...；② `uip_glue.c` 每轮 connect 重置接收环形缓冲 `rxbuf_head/tail/full`（跨轮残留污染下一轮 TLS 记录 + 缓冲末尾 space 截断大响应）

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
| 🟡 | P15-3 索引 + SELECT TO JSON（纯 pp-db，不依赖网络） | **可并行** |
| 🟡 | T-1 VGA 控制台（不依赖网络栈） | **可并行** |
| 🟡 | A-1 编译器 ARM 目标（独立于网络栈） | **可并行** |
| 🟢 | P16-1 事务 / P16-2 Rust 对照 / P16-3 教程 | 可并行 |
| 🟢 | 教程编写（P13-1~3，最后写） | 可并行 |
| 📌 | ~~uIP 集成修复未提交~~（已提交 `4a05108`/`c8ea251`/`7a31bd5`） | 已解决 |

---

## 6. 协同开发建议

1. **uIP 集成修复已提交**（`4a05108`/`c8ea251`/`7a31bd5`）：语言三层演进、db ask 收尾、数组语法迁移均已入库
2. **可并行任务**：P15-3（索引）、T-1（VGA 控制台）、A-1（ARM 目标）均可并行，
   可分配给不同人
3. **单线程任务**：无（db ask 收尾已完成，P15-1 已验收）
4. **文档现状**：roadmap.md 是任务台账，baremetal.md 是裸机设计，ppdb.md 是数据库设计
