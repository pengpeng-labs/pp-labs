# pp-lang 语言规范（spec）

> 状态：**v0.3 定版**。本文件是语言语法与语义的唯一权威来源；设计理由见 `design.md`，教学材料不得改变本文件的含义。
> 约定：扩展名 `.pp`，编译器 `pp`。

v0.3.x 只允许修复实现缺陷、补充测试和澄清文字；新增或破坏性语义进入后续语言版本。发布定版提交时使用 `pplang-v0.3.0` 标签固定兼容基线。

## 1. 定位

一门"整个能装进脑子"的语言：小到能教编译原理，低到能写操作系统（freestanding），规整到 LLM 能可靠生成。

## 2. 词法（Lexical）

- 关键字：`fn` `let` `if` `else` `while` `for` `in` `return` `struct` `enum` `switch` `import` `extern` `static` `break` `continue` `true` `false` `as` `defer`
- 标识符：`[A-Za-z_][A-Za-z0-9_]*`
- 字面量：整数 / 浮点 / 布尔 / 字符串
- 注释：`//` 行注释，`/* */` 块注释
- 运算符：算术 / 比较 / 逻辑（优先级表见 §6）

空白只分隔 token；关键字不能作为标识符。整数支持十进制与 `0x` 十六进制，字符串使用双引号，转义在词法阶段处理。v0.3 没有字符字面量，字节值写成整数。

## 3. 语法（EBNF）

```ebnf
program       = { item } ;
item          = func_decl | extern_decl | struct_decl | enum_decl | import_decl | static_decl ;
func_decl     = prototype block ;
extern_decl   = "extern" prototype ";" ;
prototype     = "fn" ident [ type_params ] "(" [ params ] ")" [ "->" type ] ;
type_params   = "[" ident { "," ident } "]" ;
type_args     = "[" type { "," type } "]" ;
params        = param { "," param } [ "," "..." ] | "..." ;
param         = ident ":" type ;
struct_decl   = "struct" ident [ type_params ] "{" [ field { "," field } [ "," ] ] "}" ;
field         = ident ":" type ;
enum_decl     = "enum" ident [ type_params ] "{" variant { "," variant } [ "," ] "}" ;
variant       = ident [ "(" type ")" ] ;
import_decl   = "import" string ";" ;
static_decl   = "static" ident ":" type [ "=" expr ] ";" ;

block         = "{" { stmt } "}" ;
stmt          = let_stmt | assign_stmt | if_stmt | while_stmt | for_stmt | switch_stmt
              | defer_stmt | return_stmt | "break" ";" | "continue" ";" | expr ";" ;
let_stmt      = "let" ( ident [ ":" type ] [ "=" expr ]
              | "(" ident "," ident { "," ident } ")" "=" expr ) ";" ;
assign_stmt   = lvalue "=" expr ";" ;
lvalue        = ident | "*" unary | postfix "." ident | postfix "[" expr "]" ;
if_stmt       = "if" "(" expr ")" block [ "else" ( if_stmt | block ) ] ;
while_stmt    = "while" "(" expr ")" block ;
for_stmt      = "for" ident "in" expr block ;
defer_stmt    = "defer" expr ";" ;
return_stmt   = "return" [ expr ] ";" ;
switch_stmt   = "switch" expr "{" switch_arm { switch_arm } "}" ;
switch_arm    = ( ident "." ident [ "(" ident ")" ] | "_" ) block ;

type          = "void" | "int" | "float" | "bool" | "str"
              | "u8" | "u16" | "u32" | "u64"
              | "[" int "]" type | "*" type
              | "fn" "(" [ type { "," type } ] ")" [ "->" type ]
              | "(" type "," type { "," type } ")"
              | ident [ type_args ] ;

expr          = binary ;
unary         = ( "-" | "!" | "~" | "&" | "*" ) unary | postfix ;
postfix       = primary { "." ident [ type_args ] [ "(" [ args ] ")" ]
                        | "[" slice_or_index "]" | "as" type } ;
slice_or_index = [ expr ] ":" [ expr ] | expr ;
primary       = literal | ident [ type_args ] ( "(" [ args ] ")" | struct_init )
              | ident | "(" expr [ "," expr { "," expr } ] ")"
              | "[" [ expr { "," expr } ] "]" ;
struct_init   = "{" [ ident ":" expr { "," ident ":" expr } ] "}" ;
args          = expr { "," expr } ;
```

`binary` 按 §6 的优先级解析；赋值是语句而不是表达式。enum 构造复用调用语法，例如 `Option.Some[int](1)`。

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

## 5. 核心语言与系统边界

- 核心语言包含静态类型、值语义、词法作用域、函数、控制流、数组、tuple、struct、enum、显式泛型和 `str` 视图。
- 核心语言不要求 GC 或隐藏运行时；普通代码可以只依赖 `stdlib/`，不接触裸内存。
- `*T`、地址转换、volatile、端口 IO 与中断控制属于系统边界。pp 不以装饰性 `unsafe` block 区分二者，而以类型、builtin 和模块职责保持边界可见。

## 6. 运算符与系统能力

二元运算符从低到高结合如下，所有二元运算符均左结合：

| 优先级 | 运算符 |
|---|---|
| 1 | `||` |
| 2 | `&&` |
| 3 | `|` |
| 4 | `^` |
| 5 | `&` |
| 6 | `== != < > <= >= in` |
| 7 | `<< >>` |
| 8 | `+ -` |
| 9 | `* / %` |

一元 `- ! ~ & *` 和后缀字段、调用、下标、切片、cast 的优先级高于二元运算。

系统能力包括：

- `*T` 裸指针 + 取址 / 解引用
- `volatile_load/store*` 内建（MMIO）
- 端口 IO、中断、时钟等目标相关 builtin
- 不提供 `unsafe {}` 或 `asm {}` 源码语法；底层能力保持为编译器内建与 C/汇编胶水

## 7. 语义

- 词法作用域：函数体与每个 block 建立作用域；允许内层 shadowing，离开 block 后恢复外层绑定
- 条件：`if`/`while` 只接受 `bool`，整数必须显式比较（如 `x != 0`）
- 整数：`int` 是有符号 i32；`u8/u16/u32/u64` 的除法、余数和顺序比较使用无符号语义
- 求值顺序：表达式操作数与函数实参从左到右求值
- 调用约定：内部 aggregate（`str`/struct/tuple）交给 LLVM 目标 ABI；extern `str` 参数降为指针，extern 不得返回无长度的 `str`
- 切片：`0 <= lo <= hi <= len(s)`，违反边界时触发 trap
- Sum Type：`switch` 的被匹配值必须是 `enum`；payload 只支持单层绑定。无 `_` 时必须覆盖所有变体；同一变体不得重复；`_` 最多一次且必须位于最后
- Sum Type 布局：编译器为每个变体分配稳定的 `i32` tag，值表示为 `{tag, payload storage}`；`switch` 降为对 tag 的 LLVM switch，不引入运行时对象或 GC
- 泛型约束：类型参数不隐式获得算术、比较、转换或条件能力；模板需要的操作必须通过普通函数指针参数显式传入
- 泛型实现：编译器按显式类型实参单态化，重复实例只生成一次；同一模板递归展开为不同实例时报错
- 泛型边界：不做类型参数推断、trait/interface、类型集合、约束求解、specialization、comptime 或泛型 extern ABI
- 内存模型：核心子集栈 + 值语义；堆仅在 std-lib 提供显式 allocator

## 8. 目标产物

| 命令 | 产物 |
|------|------|
| `pp ir` | LLVM IR（`.ll`） |
| `pp build` | 可执行（用户态） |
| `pp obj` | 目标文件（`.o`） |
| `pp os` | freestanding 裸机 ELF |

`pp run` 以 JIT 执行 `main` 并打印返回值。v0.3 不定义包清单、依赖解析或 workspace；`import` 仅按源文件相对路径递归展开，并对同一规范路径去重。

## 9. 已决边界

- `str` 是内建 `{ptr,len}` 字节切片；字符串算法位于 stdlib
- 不提供源码级 `unsafe`/`asm`、可选指针语法、GC、所有权或 borrow checker
- 不提供类型实参推导、trait/interface、类型集合、约束求解、specialization、comptime、闭包、异常或宏
- `void` 只用于无返回值函数及函数指针返回类型，不能声明普通值
- 旧数组类型 `[T; N]` 不属于 v0.3，必须写成 `[N]T`
