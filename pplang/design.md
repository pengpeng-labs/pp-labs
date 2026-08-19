# pp-lang 语言演进设计（design）

> 状态：**规划草案**。本文件是 pp-lang 语言能力的演进规划：记原则、列演进项、标优先级、划边界。
> 与 `spec.md`（权威语言规范）的关系：spec.md 描述"语言现在是什么"，本文件描述"语言要往哪走、为什么、做什么不做什么"。
> 设计参考：Rust（语法糖）、C（能力）、Zig 0.16.0（约束哲学，见 `zig-0.16.0/doc/langref/`）、Go/Python（遍历与切片的可读性共识语法）。

---

## 1. 定位（一句话）

**pplang = C 的能力 + Rust 的语法糖 + Zig 的约束哲学 + Go/Python 的可读性。**

一门"整个能装进脑子"的语言：小到能教编译原理，低到能写操作系统（freestanding），规整到 LLM 能可靠生成。

## 2. 设计原则

1. **语法极简，复杂度下放**——宁可 `if/else if` 写二十行，不要 `match` 模式匹配语法；宁可手写函数指针表，不要泛型/trait。"写的时候麻烦一点可以，语法不要麻烦"。
2. **指针必须有，但不裸奔**——freestanding 环境绕不开裸指针（MMIO/FFI/DMA/分配器），但必须给它配上信息与约束（见 §5）。
3. **类型系统 C 级别**——静态标注 + 朴素推导 + 显式转换，够用即可；不做 TAPL 的形式化深水区（多态/子类型/safety 证明）。
4. **约束靠"信息绑定 + 生命周期约定"，不靠"所有权证明"**——用切片（绑长度）、`defer` + 显式 allocator（绑生命周期）、可选指针（绑空检查）来约束指针，**不引入 borrow checker**。

## 3. 当前能力盘点（与 spec.md 对齐）

**已有**：
- 18 关键字：`fn extern if else return let while for in as defer break continue struct import static true false`
- 类型：`int`(i32) `float`(f64) `bool`(i1) `str`(=char\* null结尾) `u8/u16/u32/u64`、`struct`(值语义)、`[N]T`(长度前置)、`fn(...) -> ret`(函数指针)、`*T`
- 语句/表达式：`let`(推断+零初始化)、赋值(含 `*p=v`/`buf[i]=v`)、`return`、`if/else`、`while`、`for x in s` + `range(n)`、`defer`(退出点 LIFO)、`break/continue`、二元/一元运算、`x in s` 成员判断、显式 cast `x as T`、`struct` 构造+字段、方法糖 `p.m(x)`、下标、数组字面量 `[e,e,...]`、指针 `&x *p p[i] p+i`、指针判空 `p == 0`、函数指针调用 `fp()`
- 顶层：`fn`、`extern`(含 variadic `...`)、`struct`、`import`、`static`
- 系统层内置：`print/println`、`volatile_load/store8/16/32/64`、`outb/inb/outl/inl`、`cli/sti/hlt`、`rdtsc`、`atomic_xchg`、`int_to_ptr/ptr_to_int`、`&func`(取址)
- stdlib：`alloc.pp`(显式 alloc/free，宿主=malloc/free)、`math.pp`、`string.pp`

**spec 纸上写了但未实现**：`unsafe` `asm`

## 4. 演进清单（分三层，按优先级）

### 第一层：基础语言件（成本低，直击当前 bug）

> ✅ 已落地（2026-08）：`true/false`、`[N]T`、`for x in s` + `range(n)`、`x in s`、切片语法 `s[a:b]`、函数指针调用 `fp()`、struct 方法糖。第一层全清。

| 项 | 要改成 | 收益 |
|----|--------|------|
| `true`/`false` 字面量 | 补上，bool 成真一等公民 | 消除 `int` 冒充 bool |
| 数组语法 `[T; N]` → `[N]T` | 长度前置（Go/Zig 式），直觉 + 无符号负担 + 与切片统一 | 影响全仓库，批量改 .pp |
| `for` 循环 | `for x in s`（遍历切片/数组，Go/Python 共识语法，非 Zig 的 `for (s) \|x\|`） | 消灭满屏 `while (i < n)` |
| `range(n)` 整数序列 | 生成 0..n，配 `for i in range(n)` | 替代手写计数循环 |
| `x in s` 成员判断 | 一个运算符，返回 bool（Python 语法） | 消灭"for 循环找元素" |
| 切片语法 `s[a:b]` | 子切片/子串（Go/Python 共识，比 Zig `s[a..b]` 直观） | 配 `str` 切片化 |
| 函数指针调用 `fp()` | 现在只能 `&func` 取址 | 替代 `app_dispatch(id)` 硬编码 |
| struct 方法（纯糖） | `p.method(x)` ≡ `method(p, x)`，无 OOP 无 trait | 降噪 `db_col(rec,tid,col)` |

### 第二层：指针 + 内存约束（核心，治"C 指针满天飞"）

> ✅ 已落地（2026-08）：`str` 切片化（`{ptr,len}` + `len()` + `s[a:b]` 切片语法）、`defer`、显式 allocator（`stdlib/alloc.pp`）、显式判空（`p == 0`/`!=`）。剩指针分层（`*T` vs 切片分离），单独下一轮。

| 项 | 要改成 | 对应 Zig |
|----|--------|---------|
| **`str` 切片化** | `str = {ptr, len}`，`len(s)` 是 O(1)，`s[i]` 有边界；字面量自动带长 | `[]u8` 切片 |
| **指针分层** | 业务层切片 / 底层裸指针 `*T`（只给 MMIO/FFI/DMA） | `[]T` vs `[*]T` |
| **显式 allocator** | `alloc(n)`/`free(p)` 标准化进 stdlib + arena 整块释放 | 显式传 allocator |
| **`defer`** | `defer free(p)` 绑作用域，一个关键字 | `defer` |
| **可选指针 / 显式判空** | `?*T` 或解引用前 `if p != 0` | `?*T` |

### 第三层：类型系统收敛（C 级别，不做深水区）

> ✅ 已全部落地（2026-08）。

| 项 | 要改成 | 对应 Zig |
|----|--------|---------|
| 无隐式收窄 | `u64`→`u8` 必须显式 cast，杜绝静默截断 | 显式 `@intCast` |
| 类型不匹配报错 | 现在静默 coerce 藏隐患 | 编译错误 |
| 同名函数重定义报错 | spec §7 已记录，补上 | 编译错误 |

## 5. 指针与内存约束（核心章节）

### 5.1 病根：C 的指针"裸奔"

一个 C 指针 `char* p` 传递时，你不知道四件事：多长？谁释放？还活着吗？可能为空吗？——全压给程序员手动配对。

### 5.2 约束思路：信息绑定 + 生命周期约定

| C 的问题 | pplang 的约束 | 成本 |
|----------|--------------|------|
| 不知道多长 | 切片 `str`（绑长度） | 低 |
| 谁分配谁释放 | 显式 `alloc`/`free` + arena | 低 |
| 忘记释放 | `defer free(p)` | 低 |
| 可能为空 | 可选指针 / 显式判空 | 中 |
| 所有权混乱 | ——（**明确不做 borrow checker**） | 不做 |

### 5.3 简化原则：不全盘照搬 Zig 指针体系

Zig 有 6 种指针（`*T`、`*const T`、`[*]T`、`[]T`、`?*T`、`[:0]T`），太复杂。pplang 只取**一个核心概念「切片」**，落到内建类型 `str` 上：

- 不引入 `[]T`/`[*]T`/`[:0]T` 这套独立语法——`str` 切片化已覆盖 90% 的"指针+长度"场景
- 裸指针 `*T` 维持现状（C 风格 `p+i`/`p[i]`），留给底层
- `defer`/显式 allocator 各是"一个关键字/一个约定"，不增加语法复杂度

## 6. 基础数据结构定位

基础数据结构三件套，各管一类，动态增长交给库、不交给语言：

| 结构 | 管什么 | 状态 |
|------|--------|------|
| 定长数组 `[N]T` | 栈上、编译期长度 | ⚠️ 由 `[T; N]` 迁移而来（见 §6.2） |
| 结构体 `struct` | 异类数据组合（值语义） | ✅ 已有，保持 |
| 切片 `str` | 动态序列视图（`{ptr, len}`） | ✅ 已落地（`len()` O(1)、`s[a:b]` 切片、字面量带长） |
| 动态数组 | 可增长序列 | ✅ **要，但用标准库实现**（简单版 ArrayList，非语言内建） |

### 6.1 为什么切片是核心、且要"无借用"

Rust 的切片 `&[T]` 设计好在"指针 + 长度绑定"，但坏在它跟借用/生命周期纠缠（学切片必须先懂所有权）。pplang 借 Rust 的"分层思想 + 指针长度绑定"，绕开借用复杂度——即 Zig 的 `[]T` 形式（裸值，无借用、无 GC）。

### 6.2 定长数组语法：`[T; N]` → `[N]T`（长度前置）

`[T; N]` 里的 `;` 继承自 Rust 的"重复"语义（Rust 另有数组字面量 `[0; 5]`），但 pplang 不支持数组字面量，故 `;` 成了"无来源的符号"。**决策：改为 Go/Zig 式的长度前置 `[N]T`**，理由有三：

1. **直觉**：`[256]u8` 读作"256 个 u8"，符合人类语言习惯（先说数量再说东西）
2. **无符号负担**：去掉 `;`，每个符号自明
3. **与切片统一**：`[N]T`（定长）与 `[]T`（切片）用同一套 `[]` 语法，学一个会两个

**影响与落地**：跨仓库语法迁移——改 lexer/parser/codegen 的数组类型解析 + 批量改 ppos/ppdb/stdlib/examples 里所有 `[T; N]` 声明。当前 .pp 代码量不大（几千行），尽早迁移成本可控；落地后同步 spec.md 的 EBNF/类型系统描述。

### 6.3 动态数组：字节缓冲（标准库，非语言内建）

pplang 无泛型、无 GC，故动态数组**不能内建**（Go/Python 靠 GC）、**不能泛型**（Rust `Vec<T>`/Zig `ArrayList(T)` 都要泛型），只能走第三条路：**固定元素类型的字节缓冲**，标准库实现：

```
struct Buf {
    data: *u8,    // 数据指针
    len: int,     // 当前长度
    cap: int,     // 容量
}

fn buf_new() -> Buf          // 空缓冲
fn buf_push(b: *Buf, x: u8)  // 追加，满了 alloc 翻倍 + 拷贝 + free
fn buf_free(b: *Buf)         // 释放
```

三个关键点：

1. **元素固定 `u8`**：无泛型的代价，但协议栈 90% 场景就是"累积字节"（HTTP 响应 / JSON / DNS / SELECT 结果），够用。

2. **struct 值语义 × 可变容器的坑**：值传递时 `push` 改的是拷贝，必须指针传递 `buf_push(&b, x)`。要顺，靠 struct 方法糖支持**指针接收者 `*Buf` + 调用自动取址**（Go 的 `func (b *Buf) push()` 模式），让 `b.push(x)` 语法干净。

3. **动态数组 = 可增长的切片**：内部 `{ptr, len, cap}`，比切片多一个 `cap`，`len` 追上 `cap` 就扩容。本质是切片语法的延伸，两者同源。

## 7. 明确不做（边界）

- ❌ 所有权 / borrow checker（Rust 最痛的点）
- ❌ 泛型 / trait / 接口
- ❌ `match` 模式匹配（可用简单版 `switch` 或就 `if/else`）
- ❌ GC
- ❌ 闭包 / 异步 / 异常 / 宏
- ❌ `comptime` 元编程（Zig 的深水区）
- ❌ 多态 / 子类型 / 递归类型 / HM 推断（TAPL 主线，超纲）

## 8. 落地顺序建议

> ✅ 三步全部落地（2026-08）：第一层、`str` 切片化、`defer`+allocator、类型系统收敛均已完成并回归通过。

1. ~~先补第一层~~（`true/false`、数组语法 `[N]T`、`for x in s` + `range(n)`、`x in s`、切片语法 `s[a:b]`、函数指针调用、struct 方法）——✅ 已完成
2. ~~再做 `str` 切片化~~——✅ 已完成（`{i64,i64}` ABI + `str_ptr`/`str_len` 兼容层 + 全仓库适配）
3. ~~随后补 `defer` + 显式 allocator~~——✅ 已完成
4. ~~最后收敛类型系统~~——✅ 已完成（无隐式收窄 + 报错）

每步都单独落地 + 回归 `pp ir/run/build/obj/os` + pp-os/pp-db 测试。
