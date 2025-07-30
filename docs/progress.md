# 开发进度实录（截至 2026-08）

> 本文档如实记录当前实际开发进度、遇到的困难与卡点，供协同开发参考。
> 任务台账以 docs/roadmap.md 为准（当前 68/100 完成）；本文是"实际状态 + 困难"的补充记录。

---

## 1. 总体状态

三条主线并行推进，当前全部卡在同一处：**pp-os 网络栈的 TCP 层健壮性**。

| 线 | 状态 | 卡点 |
|---|---|---|
| 语言线（pp-lang 编译器） | ✅ 核心完成 | 无（地址模型 64 位化已解决） |
| OS 线（pp-os） | 🟡 功能齐全，网络栈重构中 | **uIP 胶水替换手写 TCP（进行中）** |
| 数据库线（pp-db） | 🟡 P14 全完成，P15 进行中 | db ask 依赖网络栈，被阻塞 |
| 裸机线（T430/RPi4） | 🟢 刚启动（B-0/B-1 完成） | 等网络栈收尾后切入 |

---

## 2. 各线实际进度

### 2.1 语言线（pp-lang）— 完成

- 编译器：lexer/parser/AST/codegen（LLVM IR，inkwell）5 个 Rust 源文件
- 命令：`pp ir / run / obj / os / build` 全可用
- 语言能力：let/while/if/struct/import/extern/数组/指针/协程/volatile/u64
- **方案B（地址模型 64 位化）已完成**：`ptr_to_int`→U64、调用/返回点 coerce、`volatile_load64/store64`、`&func` 去截断；宿主机静态数据 >4GB 无截断
- **已知编译器问题**（记于 docs/spec.md §7）：
  1. 同名函数重定义不报错（两个函数体编译进同一 LLVM 函数）
  2. variadic extern 参数错位（open 的 mode 丢失）——用 fchmod 规避
  3. 数组字面量 `[str;9]=[...]` 不支持——用辅助函数规避

### 2.2 OS 线（pp-os）— 功能齐全，网络栈重构中

已完成并验证：
- 引导（multiboot v1 → 长模式）、IDT/中断、PIT 100Hz、PS/2 键盘、VGA、串口
- 内存 FS（16 文件，128KB 池）、shell、协程、app 模型、MCP、WASM 运行时
- e1000 驱动（QEMU 82540EM）
- TLS：**BearSSL 0.6 胶水**（交叉编译 .a + extern + tls_glue.c）
- agent：DeepSeek 对话 + 工具调用（ls/sql/kv/doc），**端到端曾跑通**（三轮 200 OK）

**当前重构**：手写 TCP（net.pp/tls.pp 里的简化实现）→ **uIP 1.0 胶水**替换。
原因：手写 TCP 的 TLS 大响应接收不可靠（doff/seq/FIN/重传等边界逐个暴露）。

uIP 胶水进度：
| 步骤 | 状态 |
|---|---|
| uIP 原版 + 裁剪版独立编译 | ✅ 通过（gcc/macOS） |
| uIP 核心 TCP 状态机纯函数级测试（test_uip.c） | 🔶 进行中 |
| - T1 connect→SYN 生成 | ✅ PASS |
| - T2 SYN-ACK 处理→CONNECTED+ESTABLISHED | ✅ PASS |
| - T3 数据发送（PSH+ACK+payload "hello"） | ✅ PASS |
| - T4 数据接收（NEWDATA） | ❌ 测试程序字节序 bug 待修 |
| - T5 FIN 处理 | ❌ 同上 |
| uip_glue.c 封装 + net_* 5 接口 | ⏳ 未开始 |
| pp-os 集成（替换手写 TCP） | ⏳ 未开始 |

### 2.3 数据库线（pp-db）— P14 全完成

已完成并验证：
- P14-1~7 ✅：存储内核（页式堆表）/SQL 解析/执行器/KV/Doc/二进制持久化/宿主机双宿主
- **独立分发（D-1~D-3）✅**：CLI（cli.pp）+ 真实文件持久化 + 测试套件（golden + 跨进程），全 PASS
- P15-2 ✅：MCP 工具 sql/kv/doc

进行中：
- **P15-1 db ask**：主体已通（schema 注入 → LLM 调工具 → messages/kv/doc 落库），
  **卡在真实 LLM 多轮调用的网络健壮性**（手写 TCP 时代第三轮握手失败）。
  uIP 接入后应能收尾。

### 2.4 裸机线 — 刚启动

- B-0/B-1 ✅：编译器地址模型 64 位化 + 内核回归
- T-1/T-2（T430）、A-1~A-5（RPi4）：未开始，设计见 docs/baremetal.md

---

## 3. 当前卡点详解

### 卡点 1：uIP 测试 T4/T5（进行中，接近解决）

- **现象**：test_uip.c 的 T4（数据接收）未触发 NEWDATA
- **根因定位**：uIP 内部 `lport` 是网络序 u16 在 LE 机器的内存表示（如 260），
  测试程序 feed 帧的端口字节序与之一致性处理有误（T3 覆盖 out_frame 后偏移读错 + lport 内存表示 vs 帧字节不一致）
- **性质**：**测试程序 bug，不是 uIP 的问题**——uIP 的握手/发送已证明正确（10/15 断言通过）
- **解决**：修 feed_tcp 端口字节序（用常量 1025 而非 lport 内存值）

### 卡点 2：手写 TCP 的 TLS 大响应（已被 uIP 方案取代）

- 历史：手写 TCP 在 QEMU slirp 下 TLS 大响应（~1.5KB）接收不可靠
- 已修 5 个边界：TCP data offset、CLOSED 残留读取、FIN 检测、seq 连续性校验、tls_init 状态重置
- 仍存在：多轮工具调用（连续 3 次 TLS 连接）时偶发握手失败（BAD_SIGNATURE，残留帧混入）
- **决策**：不再深挖手写 TCP，改用 uIP 1.0 胶水（成熟 TCP 状态机）

### 卡点 3：macOS 宿主无法直接测试 uIP 网络

- uIP unix 示例依赖 Linux TAP 设备（/dev/net/tun），macOS 无
- 解决：纯函数级测试（构造帧喂 uip_input，断言输出）——**已证明有效**（10 断言过）

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
| 🔴 | uIP 测试 T4/T5 收尾（1 个字节序 bug） | 单人 10 分钟 |
| 🔴 | uip_glue.c 封装 net_* 5 接口 | 单人 |
| 🔴 | pp-os 集成 uIP（替换手写 TCP）+ db ask 全链路验证 | 单人 |
| 🟡 | P15-3 索引 + SELECT TO JSON（纯 pp-db，不依赖网络） | **可并行** |
| 🟡 | T-1 VGA 控制台（不依赖网络栈） | **可并行** |
| 🟡 | A-1 编译器 ARM 目标（独立于网络栈） | **可并行** |
| 🟢 | P16-1 事务 / P16-2 Rust 对照 / P16-3 教程 | 可并行 |
| 🟢 | 教程编写（P13-1~3，最后写） | 可并行 |
| 📌 | **git 提交策略**（全部代码未提交！） | 协同前必须解决 |
| 📌 | 提交时间轴回填（2025-06-02~07-06，作者 Lambert） | 最终统一提交时 |

---

## 6. 协同开发建议

1. **先解决 git 提交**：目前 compiler/docs/pp-os/ppdb 全部 untracked（仅 4 个历史 commit），
   协同开发前需确定分支策略（建议：main 为开发主线，功能分支提交）
2. **可并行任务**：P15-3（索引）、T-1（VGA 控制台）、A-1（ARM 目标）都与网络栈无关，
   可分配给不同人
3. **单线程任务**：uIP 集成（当前我手里）→ db ask 收尾，完成后才能解锁 P15-1 验收
4. **文档现状**：roadmap.md 是任务台账（68/100），baremetal.md 是裸机设计，ppdb.md 是数据库设计
