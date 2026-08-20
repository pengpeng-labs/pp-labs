# pp-lang 语言规范（spec）

> 状态：**v0.3**。本文件是语言、教程第 0 章、以及喂给 LLM 的上下文三者的唯一权威来源。
> 约定：扩展名 `.pp`，编译器 `pp`。

## 1. 定位

一门"整个能装进脑子"的语言：小到能教编译原理，低到能写操作系统（freestanding），规整到 LLM 能可靠生成。

## 2. 词法（Lexical）

- 关键字：`fn` `let` `if` `else` `while` `for` `in` `return` `struct` `enum` `switch` `import` `extern` `static` `break` `continue` `true` `false` `as` `defer`
- 标识符：`[A-Za-z_][A-Za-z0-9_]*`
- 字面量：整数 / 浮点 / 布尔 / 字符 / 字符串
- 注释：`//` 行注释，`/* */` 块注释
- 运算符：算术 / 比较 / 逻辑（优先级表见 §6）

空白只分隔 token；关键字不能作为标识符。整数支持十进制与 `0x` 十六进制，字符串与字符使用双引号/单引号，转义在词法阶段处理。

## 3. 语法（EBNF）

```ebnf
program     = { decl } ;
decl        = func_decl | struct_decl | enum_decl | import_decl | extern_decl | static_decl ;
func_decl   = "fn" ident [ type_params ] "(" [ params ] ")" [ "->" type ] block ;
type_params = "[" ident { "," ident } "]" ;
type_args   = "[" type { "," type } "]" ;
params      = param { "," param } [ "," "..." ] ;   (* 末尾 ... = variadic *)
param       = ident ":" type ;
struct_decl = "struct" ident [ type_params ] "{" { field } "}" ;
enum_decl   = "enum" ident [ type_params ] "{" variant { "," variant } [ "," ] "}" ;
variant     = ident [ "(" type ")" ] ;
block       = "{" { stmt } "}" ;
stmt        = let_stmt | if_stmt | while_stmt | for_stmt | switch_stmt
            | defer_stmt | return_stmt | expr_stmt ;
let_stmt    = "let" ( ident [ ":" type ] | "(" ident "," ident { "," ident } ")" )
              [ "=" expr ] ";" ;
for_stmt    = "for" ident "in" expr block ;
defer_stmt  = "defer" expr ";" ;                    (* 函数退出点 LIFO 执行 *)
switch_stmt = "switch" expr "{" switch_arm { switch_arm } "}" ;
switch_arm  = ( ident "." ident [ "(" ident ")" ] | "_" ) block ;
type        = "int" | "float" | "bool" | "str" | "u8" | "u16" | "u32" | "u64"
            | "[" int "]" type               (* 定长数组 [N]T，长度前置 *)
            | "*" type                        (* 裸指针 *)
            | "fn" "(" [ types ] ")" [ "->" type ]   (* 函数指针 *)
            | "(" type "," type { "," type } ")"     (* tuple，至少两个元素 *)
            | ident [ type_args ]            (* struct / enum / 类型参数 *)
            ;
```

表达式采用递归下降优先级解析，包含赋值外的算术、比较、逻辑、位运算、`x in s`、`range(n)`、显式 cast 与数组/tuple 字面量。

已落地表达式子集（2026-08）：
```ebnf
postfix     = primary { "." ident [ type_args ] [ "(" [ args ] ")" ]
                                                        (* 字段访问 / 方法糖 *)
                       | "[" slice_or_index "]"           (* 下标 / 切片 *)
                       | "as" type } ;
slice_or_index = [ expr ] ":" [ expr ]                    (* 切片 s[a:b]/s[a:]/s[:b]/s[:] *)
               | expr ;                                   (* 下标 s[i] *)
call        = ident [ type_args ] "(" [ args ] ")" ;      (* 普通/泛型调用 *)
```

## 4. 类型系统

- 基础类型：`int`(i32) `float`(f64) `bool`(i1) `str`(=`{ptr, len}` 字节切片，字面量带长) `u8/u16/u32/u64`
- 复合类型：`struct`（积类型、值语义）、`enum`（和类型、值语义）、`[N]T` 定长数组（长度前置 Go/Zig 式）、`fn(...) -> ret` 函数指针
- tuple：`(T1,T2,...)`，用于值、函数返回与 `let (a,b) = f()` 解构；不支持嵌套解构/下标，extern 禁止 tuple
- 系统层类型（§6）：`*T` 裸指针
- 内建：`len(x)`（str 返回运行时长度 i64，数组返回编译期长度）；切片 `s[a:b]`/`s[a:]`/`s[:b]`/`s[:]` 产生新 `str` 视图
- `str_from_ptr(ptr,len)` 从裸缓冲构造视图，`str_ptr(s)` 提取 `*u8`；二者都不转移或管理所有权
- `enum` 变体可无 payload 或携带一个 payload；构造写 `Value.Int(1)` / `Value.None()`
- 显式泛型：函数、struct、enum 可声明类型参数；使用时必须写全类型实参，如 `identity[int](1)`、`Vec[int]`、`Option.Some[int](1)`
- `sizeof[T]()` / `alignof[T]()` 返回具体类型的编译期 `u64` 常量；只接受一个类型实参和零个值实参

- 整数字面量为 `int`，浮点字面量为 `float`，`true/false` 为 `bool`；赋值、参数和返回值不在整数与 `bool`/aggregate 之间隐式转换
- 整数宽度转换沿用系统语言规则并由 LLVM truncate/zext 实现；跨整数/浮点、整数/指针转换必须使用 `as`
- struct、enum、tuple、数组与函数指针按结构或名义类型精确匹配；泛型实例是独立名义类型

## 5. safe 核心子集（默认，教学 + LLM 友好）

- 静态类型，值语义，无指针、无 GC、无隐式内存管理
- 变量（`let`）、函数、`if/else`、`while`、`struct`
- 只依赖 `stdlib/`，不接触裸内存

## 6. 系统能力（OS 专用）

- `*T` 裸指针 + 取址 / 解引用
- `volatile_load/store*` 内建（MMIO）
- 端口 IO、中断、时钟等目标相关内建
- 不提供 `unsafe {}` 或 `asm {}` 源码语法；底层能力保持为编译器内建与 C/汇编胶水

## 7. 语义

- 词法作用域：函数体与每个 block 建立作用域；允许内层 shadowing，离开 block 后恢复外层绑定
- 条件：`if`/`while` 只接受 `bool`，整数必须显式比较（如 `x != 0`）
- 整数：`int` 是有符号 i32；`u8/u16/u32/u64` 的除法、余数和顺序比较使用无符号语义
- 求值顺序：表达式与函数实参从左到右求值（待增加更完整的规范示例）
- 调用约定：内部 aggregate（`str`/struct/tuple）交给 LLVM 目标 ABI；extern `str` 参数降为指针，extern 不得返回无长度的 `str`
- 切片：`0 <= lo <= hi <= len(s)`，违反边界时触发 trap
- Sum Type：`switch` 的被匹配值必须是 `enum`；payload 只支持单层绑定。无 `_` 时必须覆盖所有变体；同一变体不得重复；`_` 最多一次且必须位于最后
- Sum Type 布局：编译器为每个变体分配稳定的 `i32` tag，值表示为 `{tag, payload storage}`；`switch` 降为对 tag 的 LLVM switch，不引入运行时对象或 GC
- 泛型约束：类型参数不隐式获得算术、比较、转换或条件能力；模板需要的操作必须通过普通函数指针参数显式传入
- 泛型实现：编译器按显式类型实参单态化，重复实例只生成一次；同一模板递归展开为不同实例时报错
- 泛型边界：不做类型参数推断、trait/interface、类型集合、约束求解、specialization、comptime 或泛型 extern ABI
- 内存模型：核心子集栈 + 值语义；堆仅在 std-lib 提供显式 allocator

### 已知编译器问题（已修复）

1. ~~**同名函数重定义**~~：✅ 已修复（2026-08）——`compile_function` 检查函数已有 body 时报"重复定义"。
2. ~~**variadic extern 参数错位**~~：✅ 已修复（2026-08）——支持 `extern fn open(path: str, flags: int, ...)` 的 `...` 语法，`fn_type` 正确设 `is_var_arg`。
3. ~~**数组字面量不支持**~~：✅ 已修复（2026-08）——支持 `let a: [4]int = [1, 2, 3, 4];`。

## 8. 目标产物

| 命令 | 产物 |
|------|------|
| `pp ir` | LLVM IR（`.ll`） |
| `pp build` | 可执行（用户态） |
| `pp obj` | 目标文件（`.o`） |
| `pp os` | freestanding 裸机 ELF |

## 9. 已决边界

- `str` 是内建 `{ptr,len}` 字节切片；字符串算法位于 stdlib
- 不提供源码级 `unsafe`/`asm`、可选指针语法、GC、所有权或 borrow checker
