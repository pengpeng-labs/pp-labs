# pp-lang v0.3 设计记录（design）

> 状态：**v0.3 已定版**。本文件记录 pp-lang 的来源、原则、演进过程与取舍。
> 与 `spec.md`（权威语言规范）的关系：spec.md 描述"语言是什么"，本文件解释"为什么这样设计"。历史段落不构成当前语义。
> 设计参考：Rust（语法糖）、C（能力）、Zig 0.16.0（约束哲学，见 `zig-0.16.0/doc/langref/`）、Go/Python（遍历与切片的可读性共识语法）。

---

## 1. 定位（一句话）

**pplang = C 的能力 + Rust 的语法糖 + Zig 的约束哲学 + Go/Python 的可读性。**

一门"整个能装进脑子"的语言：小到能教编译原理，低到能写操作系统（freestanding），规整到 LLM 能可靠生成。

## 2. 设计原则

1. **语法极简，复杂度下放**——宁可 `if/else if` 写二十行，不要完整 `match`；泛型只做显式实参，操作能力只用函数指针，不引入 trait。"写的时候麻烦一点可以，语法不要麻烦"。
2. **指针必须有，但不裸奔**——freestanding 环境绕不开裸指针（MMIO/FFI/DMA/分配器），但必须给它配上信息与约束（见 §5）。
3. **类型系统 C 级别**——静态标注 + 朴素推导 + 显式转换，够用即可；不做 TAPL 的形式化深水区（多态/子类型/safety 证明）。
4. **约束靠"信息绑定 + 生命周期约定"，不靠"所有权证明"**——用切片（绑长度）、`defer` + 显式 allocator（绑生命周期）、显式判空来约束指针，**不引入 borrow checker**。

## 3. 当前能力盘点（与 spec.md 对齐）

**已有**：
- 20 关键字：`fn extern if else return let while for in as defer break continue struct enum switch import static true false`
- 类型：`int`(i32) `float`(f64) `bool`(i1) `str`(=`{ptr,len}`)、`u8/u16/u32/u64`、`struct`(值语义)、`enum`(tagged union)、显式泛型、`[N]T`(长度前置)、`fn(...) -> ret`(函数指针)、`*T`、受限 tuple
- 语句/表达式：`let`(推断+零初始化)、赋值(含 `*p=v`/`buf[i]=v`)、`return`、`if/else`、`while`、`for x in s` + `range(n)`、`switch`、`defer`(退出点 LIFO)、`break/continue`、二元/一元运算、`x in s` 成员判断、显式 cast `x as T`、`struct`/`enum` 构造、字段、方法糖 `p.m(x)`、下标、数组字面量 `[e,e,...]`、指针 `&x *p p[i] p+i`、指针判空 `p == 0`、函数指针调用 `fp()`
- 顶层：`fn`、`extern`(含 variadic `...`)、`struct`、`enum`、`import`、`static`
- 系统层内置：`print/println`、`volatile_load/store8/16/32/64`、`outb/inb/outl/inl`、`cli/sti/hlt`、`rdtsc`、`atomic_xchg`、`int_to_ptr/ptr_to_int`、`&func`(取址)
- stdlib：`alloc.pp`(显式裸指针 alloc/dealloc)、`math.pp`、`string.pp`、`buf.pp`、`strmap.pp`、`vec.pp`(`Vec[T]`)

源码级 `unsafe`/`asm` 已明确不做；底层操作使用 compiler builtin 与 C/汇编胶水。

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

> ✅ 已落地（2026-08）：`str` 切片化（`{ptr,len}` + `len()` + `s[a:b]` 切片语法）、`defer`、显式 allocator（`stdlib/alloc.pp`）、显式判空（`p == 0`/`!=`）。

| 项 | 要改成 | 对应 Zig |
|----|--------|---------|
| **`str` 切片化** | `str = {ptr, len}`，`len(s)` 是 O(1)，`s[i]` 有边界；字面量自动带长 | `[]u8` 切片 |
| **指针分层** | 业务层切片 / 底层裸指针 `*T`（只给 MMIO/FFI/DMA） | `[]T` vs `[*]T` |
| **显式 allocator** | `alloc(n)`/`free(p)` 标准化进 stdlib + arena 整块释放 | 显式传 allocator |
| **`defer`** | `defer free(p)` 绑作用域，一个关键字 | `defer` |
| **显式判空** | 解引用前 `if p != 0`；需要携带状态时使用 Sum Type | `?*T` 的低复杂度替代 |

### 第三层：类型系统收敛（C 级别，不做深水区）

> ✅ 已全部落地（2026-08）。

| 项 | 要改成 | 对应 Zig |
|----|--------|---------|
| 无隐式收窄 | `u64`→`u8` 必须显式 cast，杜绝静默截断 | 显式 `@intCast` |
| 类型不匹配报错 | 现在静默 coerce 藏隐患 | 编译错误 |
| 同名函数重定义报错 | spec §7 已记录，补上 | 编译错误 |

### 第四层：机制借鉴（已落地）

> ✅ v0.3 已落地。两条来源：Lua 的"少 feature，多 mechanism"与 TAPL 的低阶类型机制；pp 只借思想，不抄动态运行时或复杂约束系统。

依赖链（顺序不可乱）：`多返回值（编译器）→ StrMap（标准库）→ 接口统一（先软后硬）`。

| 项 | 方案 | 成本 | 状态 |
|----|------|------|------|
| **多返回值** `(T1,T2)` | `fn f() -> (bool,int)` 使用 LLVM literal struct，支持 tuple 值与 `let (a,b)` 解构 | 编译器 + sema | ✅ v0.2 完成 |
| **Sum Type** `enum` + 精简 `switch` | tag + payload + 穷尽性检查，见 §4.1 | 两个关键字 + tag 编号/穷尽性检查/跳转表，接近 record | ✅ v0.2 完成 |
| **显式泛型** | `f[int]` / `Vec[int]` / `Option[int]`，能力用函数指针参数 | AST 单态化，无运行时与约束求解 | ✅ v0.3 完成 |
| **关联容器** `StrMap` | 标准库 FNV-1a + 开放寻址，键值都 `str`，见 §6.4 | 纯 `.pp` | ✅ v0.2 完成 |
| **接口统一** | 先"软统一"（`map_get/has/set/del/free`）；硬统一需元方法/编译期分发 | 软=零 / 硬=高 | ✅ 软统一；硬统一远期 |

- **依赖**：多返回值是 StrMap 的前置——`map_get` 无多返回值只能"空串当哨兵"，无法区分"值是空串"与"没找到"；`-> (bool, str)` 才无歧义。

### 4.1 Sum Type / tagged union（TAPL/OCaml 启发，已落地）

ppdb 的 SQL/JSON/KV 值本质是"一个值可能是 int/str/float/bool"；现在只能用 `struct { tag: int, ... }` 手写，又丑又不安全（tag 和字段对不上没人管）。Sum type = 编译器自动维护 tag 的"或"类型，是 record 的对偶（TAPL 第 11 章），成本远低于泛型。

**取舍（借思想、减语法）**：

| OCaml 能力 | 借不借 | 理由 |
|-----------|-------|------|
| tag + payload 内存布局 | ✅ 照搬 | 零魔法，编译期编号 + 存 payload |
| match → 跳转表 | ✅ 照搬 | switch on tag，零运行时开销 |
| 穷尽性检查 | ✅ 必借 | sum type 的命根子，没有就退回手写 tag |
| 单 payload 构造子 | ✅ 借 | `Int(int)` 简单 |
| 多参数构造子 `C of int*str` | ❌ 砍 | 无 tuple，多 payload 用 struct 装 |
| 嵌套模式 `Some(x,y)` / `x::xs` | ❌ 砍 | 只做一层解构 |
| 守卫 `when` | ❌ 砍 | 用 `if` 替代 |
| 通配 `_` | ✅ 借 | 穷尽性的兜底 |
| 完整 `match` 语法 | ❌ 砍 | §7 已定，换精简 `switch` |

**语法形态**：

```
enum Value { Int(int), Str(str), Bool(bool), None }

fn value_to_int(v: Value) -> int {
    switch v {
        Value.Int(i)   { return i; }
        Value.Str(s)   { return str_len(s); }
        Value.Bool(b)  { if (b) { return 1; } else { return 0; } }
        Value.None     { return 0; }
    }
}
```

- 保留四件 OCaml 血统：**穷尽性检查**（漏变体报错）、**单层解构**、**通配 `_`**、**编译期跳转表**。
- 砍掉四件：多参数构造子、嵌套模式、守卫 `when`、完整 match。
- 无 payload 变体构造写 `Value.None()`，匹配写 `Value.None`；通配 `_` 最多一次且必须放在最后。
- 成本：`enum`/`switch` 两个关键字 + tag 编号 + 穷尽性检查 + 跳转表——接近 record，远低于泛型（不用 `[]T`、不用单态化）。
- 历史定位：源自 ML（Robin Milner, 1973），经 OCaml/SML/Haskell 普及，现已是 Rust/Swift/TS/Kotlin/Python/Java 主流标配，仅 Go 缺失。

### 4.2 显式泛型边界（Ada 借鉴，v0.3 主线）

泛型 = 两个独立需求：

| 需求 | 例子 | Ada 怎么解 | pp 现状 |
|------|------|-----------|--------|
| (a) 类型参数化 | `Map[str,int]` vs `Map[int,int]` | 显式实例化 `is new` | ✅ 显式实参 + 单态化 |
| (b) 操作约束 | `T` 能比较/哈希 | 显式声明操作 `with function "<"` | ✅ 函数指针已完成 |

**核心结论**：Ada 的"显式声明操作"降级成函数指针 = `fn sort(compare: fn(T,T)->bool)`，泛型体内写 `compare(a,b)` 而非 `a < b`。pp 的"显式"哲学更倾向后者，所以 **(b) 不需要任何泛型语法，函数指针就是 Ada 的降级版**。

(a) 类型参数化由显式单态化实现；原有 `Buf`/`StrMap` 保留为领域专用容器，通用序列使用 `Vec[T]`。

v0.3 只抄 Ada 的显式实例化：

```
Ada:  with function "<"(L,R:T) is <>      泛型体内写 a < b
pp:   fn sort(a: T, compare: fn(T,T)->bool)  泛型体内写 compare(a,b)   // (b) 仍是函数指针

Ada:  package Int_Sort is new Sorting(Integer)  // 显式实例化，无推导
pp:   sort[int](...)                             // (a) 显式实例化
```

- 做：显式实例化（`sort[int]`）+ 显式声明操作（函数指针）+ 泛型 struct/enum + `sizeof[T]`/`alignof[T]`，无推导、无约束求解。
- 不做：Go 类型集合（`T: Ordered` 白名单 + 推导是负担）、Rust trait（深水区）、Zig comptime（§7 已排除）。
- 理由：Ada 的"显式 > 隐式"约束模型天生契合 pp 哲学，是"约束最强"里最轻的一条路；且 (b) 已被函数指针吃掉，剩下的 (a) 只在类型域真正变宽时才值当。
- 实现边界：泛型在 sema/codegen 前展开为普通 AST；实例名是编译器内部细节，不构成 extern ABI。

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
| 定长数组 `[N]T` | 栈上、编译期长度 | ✅ v0.2 起仅支持长度前置语法 |
| 结构体 `struct` | 异类数据组合（值语义） | ✅ 已有，保持 |
| 切片 `str` | 动态序列视图（`{ptr, len}`） | ✅ 已落地（`len()` O(1)、`s[a:b]` 切片、字面量带长） |
| 动态数组 `Buf` | 可增长字节序列 | ✅ v0.2 标准库实现 |
| 泛型向量 `Vec[T]` | 可增长同类型值序列 | ✅ v0.3 标准库实现 |
| 关联容器 `StrMap` | 键值映射（哈希表） | ✅ v0.2 标准库实现，键值都 `str` |

### 6.1 为什么切片是核心、且要"无借用"

Rust 的切片 `&[T]` 设计好在"指针 + 长度绑定"，但坏在它跟借用/生命周期纠缠（学切片必须先懂所有权）。pplang 借 Rust 的"分层思想 + 指针长度绑定"，绕开借用复杂度——即 Zig 的 `[]T` 形式（裸值，无借用、无 GC）。

### 6.2 定长数组语法：`[T; N]` → `[N]T`（长度前置）

早期 `[T; N]` 里的 `;` 借自 Rust，但在 pp 中没有足够的语义价值。v0.2 将其移除，定为 Go/Zig 式的长度前置 `[N]T`；普通数组字面量使用 `[a, b, c]`。理由有三：

1. **直觉**：`[256]u8` 读作"256 个 u8"，符合人类语言习惯（先说数量再说东西）
2. **无符号负担**：去掉 `;`，每个符号自明
3. **与切片统一**：`[N]T`（定长）与 `[]T`（切片）用同一套 `[]` 语法，学一个会两个

**落地结果**：pplc、ppos、ppdb、stdlib 与 examples 已全部迁移；parser 明确拒绝旧 `[T; N]` 语法。

### 6.3 动态数组：字节缓冲（标准库，非语言内建）

在 v0.2 尚无泛型时，动态数组先以固定元素类型的字节缓冲 `Buf` 落地。v0.3 加入显式泛型后，`Buf` 继续负责协议和 IO 字节流，通用同类型序列由 `Vec[T]` 提供；两者都属于标准库而非语言内建。

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

1. **元素固定 `u8`**：这是领域选择而不是当前语言限制；HTTP、JSON、DNS 和查询结果本来就以字节流为主。

2. **struct 值语义 × 可变容器的坑**：值传递时 `push` 改的是拷贝，必须指针传递 `buf_push(&b, x)`。要顺，靠 struct 方法糖支持**指针接收者 `*Buf` + 调用自动取址**（Go 的 `func (b *Buf) push()` 模式），让 `b.push(x)` 语法干净。

3. **动态数组 = 可增长的切片**：内部 `{ptr, len, cap}`，比切片多一个 `cap`，`len` 追上 `cap` 就扩容。本质是切片语法的延伸，两者同源。

### 6.4 关联容器：字节串 `StrMap`（标准库）

`StrMap` 在 v0.2 先于泛型落地，选择固定 `str -> str` 是因为 ppdb、配置和协议层天然以字节串为边界。v0.3 的泛型没有将它改写成万能 `Map[K,V]`：哈希、相等和生命周期能力仍应显式传入，而当前真实需求不值得增加这层复杂度。

定案：**方案 A 字节串统一**（与 Buf 同源，`{ptr,len,cap}` + alloc 翻倍）：

```
struct MapSlot { key: str, val: str, used: bool }   // used = 开放寻址墓碑
struct StrMap  { slots: *MapSlot, len: int, cap: int }

fn map_new()  -> StrMap
fn map_set(m: *StrMap, k: str, v: str)
fn map_get(m: *StrMap, k: str) -> (bool, str)   // (found, val)，依赖多返回值
fn map_has(m: *StrMap, k: str) -> bool
fn map_del(m: *StrMap, k: str)
fn map_free(m: *StrMap)
```

- 哈希：FNV-1a，开放寻址，负载因子 0.7 扩容。
- int 键/值：序列化成 8 字节定长串（嵌入式数据库本就把一切当字节）。
- 排除：`*u8` + 函数指针回调（类型擦除丢安全）、手写 N 套（代码重复）——均不选。

## 7. 明确不做（边界）

- ❌ 所有权 / borrow checker（Rust 最痛的点）
- ❌ trait / 接口、类型集合、泛型参数推导与约束求解（只做 §4.2 的显式单态化泛型）
- ❌ `match` 模式匹配（可用简单版 `switch` 或就 `if/else`）
- ❌ GC
- ❌ 闭包 / 异步 / 异常 / 宏
- ❌ `comptime` 元编程（Zig 的深水区）
- ❌ 源码级 `unsafe {}` / `asm {}` 与 `?*T` 可选指针语法
- ❌ 多态 / 子类型 / 递归类型 / HM 推断（TAPL 主线，超纲）
- ❌ Lua 万能 table / metatable 运行时反射（需动态类型 + GC + 运行时哈希，照搬=重造 Lua；关联容器走标准库 `StrMap` 见 §6.4）

## 8. 落地顺序建议

> ✅ 三步全部落地（2026-08）：第一层、`str` 切片化、`defer`+allocator、类型系统收敛均已完成并回归通过。

1. ~~先补第一层~~（`true/false`、数组语法 `[N]T`、`for x in s` + `range(n)`、`x in s`、切片语法 `s[a:b]`、函数指针调用、struct 方法）——✅ 已完成
2. ~~再做 `str` 切片化~~——✅ 已完成（`{i64,i64}` ABI + `str_ptr`/`str_len` 兼容层 + 全仓库适配）
3. ~~随后补 `defer` + 显式 allocator~~——✅ 已完成
4. ~~最后收敛类型系统~~——✅ 已完成（无隐式收窄 + 报错）

每步都单独落地 + 回归 `pp ir/run/build/obj/os` + pp-os/pp-db 测试。
