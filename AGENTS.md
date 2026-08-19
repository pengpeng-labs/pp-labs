# AGENTS.md

本文件供 AI 编码代理（以及协同开发者）快速理解本仓库，避免误入歧途。仓库内唯一权威任务台账是 [`docs/roadmap.md`](docs/roadmap.md)；本文件是它的浓缩版 + 工程惯例。

## 1. 这是什么仓库

**pp-labs**：面向系统软件的个人实验室，围绕一门自研语言 **pp** 展开的四个产品 + 教程：

| 产品 | 目录 | 说明 |
|------|------|------|
| **pplang** | `pplang/spec.md` | pp 语言规范（权威，可整份喂给 LLM 生成 `.pp`） |
| **pplc** | `pplc/` | pp 编译器：Rust + inkwell（LLVM 18），`.pp` → LLVM IR → 可执行 / JIT / 裸机 ELF |
| **ppdb** | `ppdb/` | 用 `.pp` 写的小型多模型嵌入式数据库（SQL/KV/Doc，SQLite 风格，双宿主） |
| **ppos** | `ppos/` | 用 `.pp` 写的迷你 unikernel（libos 式），ppdb 的宿主与展示场景 |
| **教程** | `tutorial/` | lang/（编译原理 + 语言）+ os/（boot → shell 的 OS 原理），**未开始** |

两条主线贯穿始终：**教学友好** + **LLM 友好**。

## 2. 目录结构

```
docs/          # roadmap.md（唯一任务台账）/ progress.md（进度实录）/ baremetal.md / ppdb.md / app-model.md / stdlib.md
pplang/        # spec.md：语言规范（权威）
pplc/          # pp 编译器（Rust + inkwell / LLVM），src/{main,lexer,parser,ast,codegen}.rs
stdlib/        # 用 .pp 写的最小标准库（math.pp / string.pp）
examples/      # 可运行的 .pp 示例（fib/hello/struct/sum/print/volatile）
ppdb/          # 嵌入式数据库：db_core/db_sql_*/db_kv/db_doc/db_persist/host_*/cli/main + tests/
ppos/          # freestanding unikernel：kernel/fs/net/tls/json/agent/browser/mcp/wasm/app + boot/（汇编+C 胶水）
tutorial/      # lang/ + os/（仅占位 README，正文未写）
tools/         # 工具脚本（当前为空，规划：extern 声明生成器）
third_party/   # 只读第三方参考：uip-1.0/（TCP 栈）、eggos/（unikernel 参考）
```

## 3. 术语与命名约定

- 语言 `pp-lang`，扩展名 `.pp`，编译器可执行 `pp`。
- OS 叫 `pp-os`，数据库叫 `pp-db`，编译器 crate 目录叫 `pplc`。
- `.pp` 源码文件命名：小写 + 下划线（`net.pp`、`db_core.pp`）。
- **"胶水模式"**：接入第三方 C 库（BearSSL、uIP）的统一做法 = 交叉编译 `.a` + `extern` 声明 + 手写 C 胶水文件（`ppos/boot/tls_glue.c`、`uip_glue.c`）。不要为这类需求新增语言特性。
- `pp-os` 中 `kernel.pp` 是 64 位内核主文件；`boot/` 放两阶段启动汇编（32 位壳内嵌 64 位内核）与 C 胶水。
- 明确不做：GC、borrow checker、SMP 多核、GUI、完整包管理器（见 `docs/roadmap.md` 末尾"明确不做/边界"）。

## 4. 构建 / 测试 / 运行

编译器（依赖 LLVM 18，`brew install llvm@18`，路径已写进 `pplc/.cargo/config.toml`）：

```bash
cd pplc && cargo build            # 产物 target/debug/pp
./target/debug/pp ir    ../examples/fib.pp    # 输出 LLVM IR
./target/debug/pp run   ../examples/fib.pp    # JIT 执行 -> 55
./target/debug/pp build ../examples/hello.pp -o hello
./target/debug/pp obj   ../ppdb/cli.pp -o /tmp/x.o   # 目标文件（+ cc 链接）
./target/debug/pp os    kernel.pp -o kernel.o         # freestanding 裸机目标
```

pp-os（两阶段构建：64 位内核内嵌进 32 位 multiboot ELF，见 `ppos/Makefile`）：

```bash
cd ppos && make            # kernel.elf
make run                   # qemu-system-x86_64 -kernel kernel.elf -nographic
make clean                 # 会清 boot/uip/*.o 与 libuip.a
```

pp-db 宿主机测试（golden + 跨进程持久化，全绿）：

```bash
bash ppdb/tests/run_tests.sh [ppdb 二进制路径]   # 缺省会现场编译 cli.pp
```

构建产物均被 `.gitignore` 忽略（`*.o *.a *.elf *.bin *.img`、`pplc/target/`）。

## 5. 当前进度（截至 2026-08）

- **语言/编译器**：✅ 核心完成。`pp ir/run/build/obj/os` 全可用；类型含 `int/float/bool/u8~u64/struct/数组/指针/协程`；地址模型 64 位化（方案B）已落地；语言三层演进（L1 语法糖 / L2 str 切片化 / L3 类型收敛）已落地，spec §7 三个已知问题已修复。
- **pp-db**：✅ P14 全完成 + 独立分发（CLI + 真实文件持久化 + 测试全绿）+ P15-1（`db ask`，含 SQL `SELECT *` 支持）+ P15-2（MCP sql/kv/doc 工具）。
- **pp-os**：✅ 功能齐全（boot/中断/PIT/键盘/VGA+串口/内存 FS/shell/协程/app 模型/MCP/WASM/e1000/TLS(BearSSL)/DeepSeek agent）。✅ **uIP 1.0 胶水端到端打通**（手写 TCP 已归档；DNS→TCP→TLS→HTTPS→DeepSeek tool_call 全链路验证通过）。
- **裸机**：🟢 刚启动。B-0/B-1（地址模型 64 位化 + QEMU 回归）完成；T430（T-1/T-2）与 RPi4（A-1~A-5）未开始。

## 6. uIP 集成（✅ 已收尾）

手写 TCP（`ppos/archive/net.pp`、`ppos/archive/tls.pp` 已归档）已由 **uIP 1.0 胶水**替换完成，端到端验证通过。集成期间修复 6 个 bug（均在 ppos 侧，非 uIP 本身）：

| # | 位置 | 根因 |
|---|---|---|
| 1 | `kernel.pp` PIT | `tick_count` 每 10 tick 清零 → uIP periodic 驱动永不触发 |
| 2 | `net.pp` `dns_parse` | answer 偏移 `i+12+rdlen` 应为 `i+10+rdlen` |
| 3 | `uip_glue.c` init | 未设 `uip_setdraddr`/`uip_setnetmask` → 跨网段直接 ARP 目标 IP 而非网关 |
| 4 | `uip_glue.c` DNS | `uip_send` 后查 `uip_len` 判成功是错的 → 改收到响应才清 pending |
| 5 | `uip_glue.c` TCP | `uip_glue_send` 覆盖式缓冲丢 TLS 多记录 → 改累积 |
| 6 | `uip_glue.c` TCP | 累积数据 > MSS 溢出 `uip_buf` → 按 MSS 分片 |

**db ask 收尾（✅ 已解决）**：① SQL `SELECT *`（`db_sql_parse.pp` 解析 `*` 通配 + `db_sql_exec.pp` 展开列占位 c0/c1/...）；② 多轮 TLS 连接健壮性（`uip_glue.c` 每轮 connect 重置接收环形缓冲 `rxbuf_head/tail/full`）。详见 `docs/progress.md` §3 卡点4。

## 7. 还有什么没干（候选任务，取 `docs/roadmap.md` 未勾选项）

按是否可并行归类：

- **🔴 单线程（当前主线）**：无——db ask 收尾（P15-1）已提交完成。
- **🟡 可并行（不依赖网络栈）**：
  - P15-3：关系索引（`CREATE INDEX`，参考移植）+ `SELECT ... TO JSON`（纯 pp-db）。
  - T-1：VGA 文本控制台（串口双输出）+ GRUB 引导镜像（`gfxpayload=text`）。
  - A-1：编译器 ARM 目标（`pp arm64`）+ x86 内建 ARM 化（outb/inb→MMIO、cli/sti/hlt→DAIF/wfi、rdtsc→CNTPCT_EL0）。
  - P16-1：事务（BEGIN/COMMIT/ROLLBACK，UNDO 日志）+ 表锁。
- **🟢 可并行（长期）**：
  - P16-2：`tools/ppdb-ref` Rust 对照实现 + golden tests。
  - P16-3 / P13-1~3：教程编写（lang 编译原理 + os 原理 + 数据库原理），最后写。
  - P4-3：`pp` 单二进制工具链补全（`build/ir/obj/run/test`）。
  - P4-4 / P13-3：`stdlib.md`、`spec.md`、`design.md` 定稿对齐。
  - T-2 / A-2~A-5：真机部署（T430 legacy 引导 + 82579LM 网卡；RPi4 启动桩 + PL011/GIC/GENET 驱动 + BearSSL aarch64 交叉编译）。
- **📌 注意**：`docs/progress.md` §5 提到的"代码全部未提交"已过时——仓库已重组并提交；uIP 集成修复、语言三层演进、db ask 收尾均已提交（`4a05108` / `c8ea251` / `7a31bd5`）。

## 8. 关键事实 / 陷阱

- **任务台账唯一来源是 `docs/roadmap.md`**；`docs/progress.md` 是"实际状态 + 困难"的补充。改进度时两处都要对齐。
- **`third_party/` 只读**，不自造的部分（uIP、eggos、wasmi 参考）只参考/移植，不改动。
- 索引（SkipList/B+树）、WASM 运行时、TCP 栈都是**参考现成实现移植简化**，不从头发明；存储内核/SQL 解析器/执行器等原理主线用 pp-lang 手写（见 `docs/ppdb.md` §2）。
- pp-os 单地址空间、全部 ring0、无进程隔离，app = 协程 + 库（边界契约见 `docs/app-model.md`）。
- pp-db 有 4 个 host 抽象文件（`host_ppos.pp` / `host_native.pp` / `host_file_ppos.pp` / `host_file_native.pp`）：宿主机宿主走真实文件（POSIX + fchmod），pp-os 宿主走内存页区 + fs_write_bin。
