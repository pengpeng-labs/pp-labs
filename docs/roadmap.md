# pp-lang 路线图

> pp-lang 的三位一体：**一门语言** + **两个教程**（语言 / OS）+ **一个 demo（pp-os）**。
> 两条主线：**教学友好** + **LLM 友好**。
> 本文件是唯一的任务台账，阶段推进时在此勾选。

约定：语言 `pp-lang`，扩展名 `.pp`，编译器 `pp`。

---

## Phase 0 — 规范与地基

- [ ] **D0-1** 定名：语言 `pp-lang`、扩展名 `.pp`、OS `pp-os`、教程名
- [ ] **D0-2** `docs/spec.md`：词法 + EBNF 语法 + 类型系统 + safe/system 子集边界
- [ ] **D0-3** `docs/stdlib.md`：最小标准库 API 清单定稿
- [ ] **D0-4** `docs/design.md`：设计理念与 blueprint（为什么这么设计）
- [x] **D0-5** 已决：编译器名 `pp`、教程双语（中英）
- [ ] **D0-6** 仓库更名决策：GitHub 仓库 `xlc-lang` → `pp-lang`（需手动操作，不在此仓库内改）

## Phase 1 — 编译器骨架（Rust + inkwell）

- [x] **P1-1** `compiler/` 初始化 Cargo crate（名称 `pp`）+ `inkwell` 依赖
- [x] **P1-2** `lexer.rs`：tokenizer（关键字 / 标识符 / 字面量 / 运算符 / 注释）
- [x] **P1-3** `ast.rs`：AST 定义（enum + struct，Rust 惯用）
- [x] **P1-4** `parser.rs`：递归下降解析（手写，教学价值高）
- [x] **P1-5** `codegen.rs`：AST → LLVM IR（inkwell）
- [x] **P1-6** `main.rs` CLI：`pp ir/build/run`

## Phase 2 — 最小闭环

- [x] **P2-1** `.pp` → LLVM IR → 可执行 全链路跑通
- [x] **P2-2** `examples/hello.pp` 输出 hello world
- [ ] **P2-3** `tutorial/lang/01-lexer.md`、`02-parser.md`、`03-codegen.md`（编译器开发日志）

## Phase 3 — 语言核心（safe 子集）

- [x] **P3-1** 变量 / 作用域 / 可变性
- [x] **P3-2** 控制流：`if/else`、`while`
- [x] **P3-3** 函数定义 / 参数 / 返回值 / 调用约定
- [x] **P3-4** `struct`（值类型）
- [x] **P3-5** 运算符与优先级表
- [ ] **P3-6** `tutorial/lang/04~06`：语义与特性章节

## Phase 4 — 标准库与工具链

- [x] **P4-1** `stdlib/` 用 `.pp` 自举（`math.pp`：abs/max/min）
- [x] **P4-2** `print`/`println` 内置 + `extern` 边界（JIT 自动解析 libc 符号）+ `import` 多文件
- [ ] **P4-3** `pp` 单二进制工具链补全（`build/ir/obj/run/test`）
- [ ] **P4-4** `docs/stdlib.md` 定稿并与实现对齐

## Phase 5 — freestanding 目标（系统子集）

- [x] **P5-1** 无 libc 目标：自定义 `_start` + 链接脚本 + 零 BSS
- [x] **P5-2** emit 裸机 ELF（`pp os`，交叉编译 x86_64）
- [x] **P5-3** 系统层：`volatile_store8/16/32`、`volatile_load8/16/32`、`outb`/`inb`（端口 IO）、十六进制字面量；底层能力固定为 builtin/C/汇编胶水
- [ ] **P5-4** `tutorial/os/00`：freestanding 开篇

## Phase 6 — pp-os v0（demo）

- [x] **P6-1** multiboot v1 启动 + 长模式 + 零 BSS / 设栈（两阶段：64 位内核内嵌进 32 位 ELF）
- [x] **P6-2** VGA（内存映射）/ 串口（IO 端口 outb）输出
- [x] **P6-3** IDT 中断 + 键盘 + PIT 定时器
- [x] **P6-4** bump allocator
- [x] **P6-5** 简单 shell（行编辑 + 命令：help/about/clear/echo）
- [ ] **P6-6** `tutorial/os/01~05`：OS 教程对应章节

## Phase 7 — 进阶：协程（已完成）

- [x] **P7-1** 协作式协程（switch_context + make_context + yield）
- [x] **P7-2** `&func` 函数指针（协程入口）
- [ ] **P7-3** 更完整 allocator（free-list / slab）→ 归入 Phase 8
---

## Phase 8 — 语言地基：类型 / 数组 / 字符串 / 指针 / 内存

> v6 网络栈与文件系统的前置，优先做。

- [x] **P8-1** `u8/u16/u32/u64` 无符号类型 + 类型强制转换（truncate/zext）+ 整数提升
- [x] **P8-2** 数组（`let buf: [int; 256]`）+ 下标 `buf[i]`（含 `buf[i] = v`）
- [x] **P8-3** 字符串 stdlib（`stdlib/string.pp`：strlen/strcmp/strcpy/strcat）
- [x] **P8-4** 极简指针：`*T` 类型 + `&` / `*` / `[]` / `+`（含 `*p = v` 解引用赋值）
- [ ] **P8-5** `free()` / free-list（或 slab）allocator → 并入 v4 文件系统
- [ ] **P8-6** （可选）struct 方法（驱动/协议封装）

## Phase 9 — pp-os v4：文件系统 + shell 强化

- [x] **P9-1** 自旋锁（`atomic_xchg` + 自旋）
- [x] **P9-2** 内存文件系统（16 文件 × 名 32B + 内容 256B，`fs.pp`）
- [x] **P9-3** shell 命令扩展（`ls/cat/write/rm`，含参数解析）
- [x] **P9-4** shell 脚本（`run <file>` 逐行执行，忽略 `#` 注释/空行——已验证 echo/ls/app list 脚本执行）

## Phase 10 — pp-os v5：网络栈（咽喉点）

- [x] **P10-1** 网卡驱动 e1000（PCI 枚举 + MMIO + 收发描述符环 + ARP）
- [x] **P10-2** IPv4 + UDP + DNS（校验和 + 静态 IP + 网关解析）
- [x] **P10-3** TCP 客户端（三次握手）+ HTTP/1.0 客户端

## Phase 11 — pp-os v6：LLM 连接层

- [x] **P11-1** JSON 解析器——`json.pp`：HTTP chunked 解码（`unchunk`）+ JSON 字符串字段提取（`json_find_str`，含转义）+ `json_escape`
- [x] **P11-2** DeepSeek API 客户端（OpenAI 兼容）——`https_post` + `ds` 命令：TLS 1.2 握手 + Bearer 认证 + JSON body + 真实调用验证（`ds hello` → 200 OK + LLM 回答）
- [x] **P11-3** 配置文件 + API key 存于文件系统——`fs_init` 预置 `key` 文件，`ds` 命令从 FS 读取；`write key <key>` 可覆盖

## Phase 12 — pp-os v7：Agent + 生态

- [x] **P12-2a** 内嵌 agent 协程（多轮对话）：历史消息存内存缓冲（0x675000），`ds` 请求携带完整对话历史（含转义）；修复第二轮连接失败（源端口轮换 + SYN 残留过滤 + 分块状态重置）
- [x] **P12-2b** agent 工具调用——`agent.pp`：请求带 tools 定义（ls）→ 解析 tool_calls（json_find_after 避开顶层 id）→ 内核执行（fs_list_str）→ tool 消息回传（≤3 轮）；真实验证 `ds list my files` → LLM 调用 ls → 基于真实 FS 列表回答。附带修复：Makefile 依赖补全、PIT 编程 100Hz、握手残留记录过滤（应用阶段丢弃 22/20 类型）、pump hlt 让出
- [x] **P12-1** MCP（JSON-RPC 2.0 + 工具协议层）——mcp.pp：tools/list、tools/call、initialize；agent 工具调用走 MCP；mcp list / mcp call ls 验证通过
- [ ] **P12-3** CLI 浏览器（HTTP + 文本渲染）
- [ ] **P12-4** WASM 运行时（移植/写最小核心解释器，供"装程序"）

## Phase 13 — 教程（最后写）

- [ ] **P13-1** `tutorial/lang`：lexer → parser → codegen 开发日志（P2-3、P3-6 合并）
- [ ] **P13-2** `tutorial/os`：boot → 中断 → shell → 协程（P5-4、P6-6 合并）
- [ ] **P13-3** `docs/spec.md`、`docs/stdlib.md`、`docs/design.md` 定稿对齐

## Phase 13.5 — App 模型：内核有边界（"程序 = 协程 + 库"落地）

> 内核 = 机制（fs/net/tls/json/协程/app 注册表）；应用 = 策略（browse/ds/sql/WASM 程序）。
> 设计文档：docs/app-model.md

- [x] **A0** `free-list` allocator（kmalloc 切分 + kfree 回收，P8-5 并入）
- [x] **A1** `app.pp` 注册表：app list/run/help（名字/描述/入口）
- [x] **A2** 迁移 browse → app（第一个正式程序）
- [x] **A3** 迁移 ds(agent) → app
- [x] **A4** shell 分层：系统命令 + app 分发
- [x] **A4b** shell 脚本（P9-4 并入）
- [x] **A5** `docs/app-model.md` 程序模型文档 + 内核 API 清单（边界契约）
- [x] **A6** 库边界整理：browser 库化（web_fetch + html_to_text）+ agent 库化（agent_chat），app 入口为薄壳

## Phase 13.7 — CLI 浏览器（P12-3）

- [x] **B1** `browser.pp`：HTML → 纯文本（标签剥离 + 实体解码 + 注释/script/style 跳过 + 块级标签换行）
- [x] **B2** `http_get_host`（任意主机 + Host 头 + 端口语法 host:port）
- [x] **B3** `browse` 命令（IP 直连/DNS 解析 + 文本渲染）——真实验证：本地 HTML 页渲染正确
- [ ] **B4**（可选）gzip 解压 + readability 正文提取（v2，参考 w3m/gumbo/readability）

## Phase 13.6 — WASM 动态加载（app 模型最终形态）

- [x] **W1** WASM 加载器（magic/version/section 解析 + LEB128，参考 wasmi）
- [x] **W2** 最小解释器（i32 常量/算术/比较/load/store/store8/local/call；add(3,4)=7 验证）
- [x] **W3** 最小 WASI（fd_write import → 串口；hello.wasm 输出 "hi" 验证）
- [x] **W4** `wasm install <file> <hex>`（hex→二进制存 FS）+ `wasm run <file>`（解析→运行→WASI 输出）——demo.wasm 安装/运行验证通过（"程序即文件"闭环）

## Phase 14 — pp-db：利于 agent 的多模型嵌入式数据库（设计见 docs/ppdb.md）

> 定位：独立小型多模型数据库（RDB + KV + Doc，SQLite 风格），pp-os 为首个宿主（存 LLM 会话/上下文/配置）；双宿主（pp-os + 宿主机）。
> 原理主线（存储/缓冲池/解析器/执行器）手写；索引参考移植（SkipList/B+树思想），不从头发明。

- [x] **P14-1** 存储内核：页式堆表（页链+slot array）+ 页分配（页号从 1 起）+ 扫描迭代器——pp-os 内验证通过（建表/插入/扫描）
- [x] **P14-2** SQL lexer/parser（CREATE/DROP/INSERT/SELECT(WHERE/LIMIT)/UPDATE/DELETE）——pp-os 验证通过
- [x] **P14-3** 执行器（seq_scan/filter/project/CRUD + 表格式输出）——验证通过
- [x] **P14-4** KV 接口（有序映射：SkipList 参考移植）+ Doc 接口（json.pp 复用）——pp-os 验证通过（put/get/del + doc put/get）
- [x] **P14-5** `sql`/`db` 命令 + app 注册 + 表格式输出——验证通过（db create/list/drop、真实 DROP TABLE、app list 含 sql/db）
- [x] **P14-6** 二进制 `db save/load`（fs_write_bin）——验证通过（表/KV/Doc/页区整库镜像，多页表往返恢复正确）
- [x] **P14-7** 宿主机宿主跑通——验证通过（`pp run` JIT 与 `pp obj`+cc 双路径，建表/插入/扫描输出正确）

## Phase 15 — pp-db v2：Agent 结合

- [x] **P15-1** `db ask`（NL→操作）+ agent 数据模型（messages 表/kv 状态/doc 会话，替代 0x675000）——网络链路 + SQL `SELECT *` + 多轮 TLS 连接健壮性全打通（DNS→TCP→TLS→HTTPS→DeepSeek tool_call 全通）
- [x] **P15-2** MCP 工具（sql/kv/doc 三类）——验证通过（JSON-RPC tools/list + tools/call：SELECT 表格式返回、kv put/get、doc put/get 含 JSON 转义）
- [ ] **P15-3** 关系索引（CREATE INDEX，参考移植）+ `SELECT ... TO JSON`

## Phase 16 — pp-db v3 + 对照实现（可选）

- [ ] **P16-1** 事务：BEGIN/COMMIT/ROLLBACK（UNDO 日志）+ 表锁
- [ ] **P16-2** `tools/ppdb-ref`：Rust 对照实现 + golden tests
- [ ] **P16-3** pp-db 教程章节（数据库原理 × pp-lang × Agent）

## Phase 17 — 裸机部署（设计见 docs/baremetal.md）

> 两个真机平台：ThinkPad T430（x86-64，同架构验证）+ Raspberry Pi 4B 8GB（ARM64，独立移植线）。
> 共同前置：编译器地址模型 64 位化（方案B，B-0）。
> **决策（2026-08）**：ARM64 A-1~A-5 全线搁置，不进入 pplang v0.3；恢复时另开独立里程碑。

- [x] **B-0** 编译器地址模型 64 位化——完成（`ptr_to_int`→U64、调用/返回点 coerce、`volatile_load64/store64`、`&func` 去截断）
- [x] **B-1** QEMU 全链路回归（P14-1~6 零行为变化）+ pp-db 宿主机宿主跑通（P14-7，JIT/obj 双路径）
- [ ] **T-1** VGA 文本控制台（串口双输出）+ GRUB 引导镜像（gfxpayload=text）
- [ ] **T-2** T430 实机：legacy U 盘引导 → 键盘交互 → 82579LM 网卡适配
- [ ] **A-1** 编译器 ARM 目标（`pp arm64`）+ x86 内建 ARM 化（outb/inb→MMIO、cli/sti/hlt→DAIF/wfi、rdtsc→CNTPCT_EL0）
- [ ] **A-2** aarch64 启动桩 + kernel8.img + SD 卡布局（start4.elf/fixup4.dat/config.txt）
- [ ] **A-3** RPi4 驱动移植：PL011 串口 → ARM 定时器 → GIC → GENET 网卡
- [ ] **A-4** BearSSL 交叉编译（aarch64）→ 网络栈验证
- [ ] **A-5** RPi4 实机引导（8GB 内存利用依赖方案B）

## Phase 18 — 语言演进（design.md §4 落地）

> 规划见 `pplang/design.md`。目标：pplang = C 能力 + Rust 语法糖 + Zig 约束哲学 + Go/Python 可读性。分三层按优先级落地。

### 第一层：基础语言件（纯糖，成本低）

- [x] **L1-1** `true`/`false` 字面量（bool 成真一等公民）
- [x] **L1-2** 数组语法 `[T; N]` → `[N]T`（长度前置，全仓库迁移）
- [x] **L1-3** `for x in s` 遍历循环 + `range(n)` 整数序列
- [x] **L1-4** `x in s` 成员判断（返回 bool）
- [x] **L1-5** 函数指针调用 `fp()`
- [x] **L1-6** struct 方法（纯糖，`p.method(x)` ≡ `method(p, x)`）

### 第二层：指针 + 内存约束（核心）

- [x] **L2-1** `str` 切片化（`{ptr, len}`，O(1) len，字面量带长）——str 表示 `{i64,i64}`（arm64 ABI）+ `str_ptr`/`str_len` 兼容层 + int_to_ptr 返回 str + 全仓库字符串适配 + `print/println` 按 len 打印
- [x] **L2-2** 切片语法 `s[a:b]` + `len()` 内建（`s[a:]`/`s[:b]`/`s[:]` 齐全）
- [x] **L2-3** 显式 allocator（`stdlib/alloc.pp`：宿主 = malloc/free；pp-os 用 kmalloc/kfree）
- [x] **L2-4** `defer`（函数退出点 LIFO 执行）
- [x] **L2-5** 显式判空（指针 `==`/`!=` 比较，`p == 0` 判空；不新增可选指针语法）

### 第三层：类型系统收敛

- [x] **L3-1** 无隐式收窄（u64→u8/u16 字节级截断必须显式 `as`；int→u8 惯用收窄保留）
- [x] **L3-2** 类型不匹配报错（int→bool 等隐式转换拒绝）
- [x] **L3-3** 同名函数重定义报错（spec §7）

### 附：spec §7 已知问题修复

- [x] **S7-2** variadic extern（`extern fn printf(fmt: str, ...)`，`...` 语法，修 mode 丢失）
- [x] **S7-3** 数组字面量（`let a: [4]int = [1, 2, 3, 4];`）
- [x] **S7-cast** 显式 cast 语法（`x as u8`，int↔float/int↔指针/int 收窄拓宽）

每步落地 + 回归 `pp ir/run/build/obj/os` + pp-os/pp-db 测试。

## Phase 19 — pplang v0.2：语义收口 + 实用机制

- [x] **L4-0** 编译器黑盒回归测试 + 小型 `sema.rs`（名字/作用域/调用/返回/基础类型）
- [x] **L4-1** 无符号除法/余数/比较 + `if/while` 严格 bool + block shadowing
- [x] **L4-2** 移除旧 `[T; N]` 语法；`str` 长度语义、extern 返回边界、切片运行时边界检查
- [x] **L4-3** struct 字段左值 + `*Struct` 字段访问 + 指针接收者方法自动取址
- [x] **L4-4** 受限 tuple：类型/值/返回/`let (a,b)` 解构（无嵌套解构、无 extern tuple）
- [x] **L4-5** `stdlib/buf.pp` 可增长字节缓冲
- [x] **L4-6** `stdlib/strmap.pp`（FNV-1a + 开放寻址 + 扩容 + owned key/value）
- [x] **L5-1** Sum Type：`enum` + 精简 `switch` + 单层解构 + 穷尽性检查（LLVM `{tag,payload}` + switch，构造/错误路径黑盒测试）

每项验收：`cargo test` + `pp ir/run/build/obj/os` + pp-db golden/持久化 + pp-os 全量重建。

## Phase 20 — pplang v0.3：Ada 式显式泛型

- [x] **G0-1** 边界收敛：删除源码级 `unsafe`/`asm` 与 `?*T` 规划；ARM64 target 搁置
- [x] **G0-2** 类型查询失败必须报错，移除 codegen `typeof_expr` 的静默 `int` 回退
- [x] **G1-1** 泛型函数声明 `fn f[T]` + 显式调用 `f[int](...)`
- [x] **G1-2** 模板语义检查：`T` 不隐式获得算术/比较能力，能力用 `fn(T,...)` 参数显式传入
- [x] **G1-3** AST 单态化工作队列、实例去重、递归膨胀检测与内部符号 mangling
- [x] **G2-1** 泛型 `struct` / `enum` 与具体类型 `Vec[int]` / `Option[str]`
- [x] **G2-2** 泛型 struct 构造、enum 构造与 Sum Type 穷尽检查
- [x] **G2-3** 嵌套实例（如 `Option[Vec[int]]`）与实例布局去重
- [x] **G2-4** `sizeof[T]()` / `alignof[T]()` 编译期整数内建
- [x] **G3-1** v0.3 spec/design 定稿 + 泛型正反例 + 全仓库回归（compiler 35/35、pp-db PASS、pp-os 全量重建）

边界：不做类型参数推导、trait/interface、类型集合、约束求解、specialization、comptime、泛型 extern ABI。

---

## 明确不做 / 边界

- ❌ GC（eggos 最痛的点，教学不碰）
- ❌ borrow checker / 所有权（Rust 最痛的点）
- ❌ SMP / 多核
- ❌ GUI（图形界面，CLI 浏览器除外）
- ❌ 完整包管理器（"装程序"用 WASM/脚本 + 文件系统）
- ⚠️ TLS：从零写不现实 → 已用 **BearSSL 0.6**（knownkey 固定公钥跳过链验证）验证通过：HTTPS GET/POST → DeepSeek 200 OK

## 移植参考（不自造的部分）

- 网络栈：参考 eggos `inet/`（`third_party/eggos/inet/`）
- WASM 运行时：参考 wasmi（Rust）
- TLS：**BearSSL 0.6**（交叉编译 libbearssl.a + freestanding 胶水，knownkey 固定公钥；已端到端验证）
- 文件系统：参考 xv6 的 FS 设计

## 关键参考

- LLVM Kaleidoscope 教程：https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/index.html
- Writing an OS in Rust：https://os.phil-opp.com/
- eggos（unikernel 参考）：`third_party/eggos/`

## 提交时间轴（备忘，最终统一提交时用）

- 起点 commit（想法）：**2025-02-26**（已存在于历史，保留不动）
- 开发期：**2025-06-02 ~ 07-06**，共 5 周，按真人节奏分批提交
  - W1 06-02~08 Phase 0（spec/目录/命名）
  - W2 06-09~15 Phase 1（lexer/parser/ast）
  - W3 06-16~22 Phase 2（codegen/CLI/hello world）
  - W4 06-23~29 Phase 3+4（let/while/struct + stdlib）
  - W5 06-30~07-06 Phase 5+6（freestanding + pp-os + 教程）
- 提交时：设置 `GIT_AUTHOR_DATE` 与 `GIT_COMMITTER_DATE`；作者统一 `Lambert <labspc@163.com>`
