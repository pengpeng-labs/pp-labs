# pp-lang 语言规范（spec）

> 状态：**v0.2 草案**。本文件是语言、教程第 0 章、以及喂给 LLM 的上下文三者的唯一权威来源。
> 约定：扩展名 `.pp`，编译器 `pp`。

## 1. 定位

一门"整个能装进脑子"的语言：小到能教编译原理，低到能写操作系统（freestanding），规整到 LLM 能可靠生成。

## 2. 词法（Lexical）

- 关键字：`fn` `let` `if` `else` `while` `for` `in` `return` `struct` `import` `extern` `static` `break` `continue` `true` `false` `as` `defer`（`unsafe` `asm` 纸上待实现）
- 标识符：`[A-Za-z_][A-Za-z0-9_]*`
- 字面量：整数 / 浮点 / 布尔 / 字符 / 字符串
- 注释：`//` 行注释，`/* */` 块注释
- 运算符：算术 / 比较 / 逻辑（优先级表见 §6）

TODO：补全精确 token 定义。

## 3. 语法（EBNF）

```ebnf
program     = { decl } ;
decl        = func_decl | struct_decl | import_decl | extern_decl | static_decl ;
func_decl   = "fn" ident "(" [ params ] ")" [ "->" type ] block ;
params      = param { "," param } [ "," "..." ] ;   (* 末尾 ... = variadic *)
param       = ident ":" type ;
struct_decl = "struct" ident "{" { field } "}" ;
block       = "{" { stmt } "}" ;
stmt        = let_stmt | if_stmt | while_stmt | for_stmt | defer_stmt | return_stmt | expr_stmt ;
let_stmt    = "let" ( ident [ ":" type ] | "(" ident "," ident { "," ident } ")" )
              [ "=" expr ] ";" ;
for_stmt    = "for" ident "in" expr block ;
defer_stmt  = "defer" expr ";" ;                    (* 函数退出点 LIFO 执行 *)
type        = "int" | "float" | "bool" | "str" | "u8" | "u16" | "u32" | "u64"
            | "[" int "]" type               (* 定长数组 [N]T，长度前置 *)
            | "*" type                        (* 裸指针 *)
            | "fn" "(" [ types ] ")" [ "->" type ]   (* 函数指针 *)
            | "(" type "," type { "," type } ")"     (* tuple，至少两个元素 *)
            | ident                          (* 结构体名 *)
            ;
```

TODO：补全表达式层（`expr`/优先级，含 `x in s` 成员判断、`range(n)` 序列、`expr as type` 显式 cast、`[e, e, ...]` 数组字面量）。

已落地表达式子集（2026-08）：
```ebnf
postfix     = primary { "." ident [ "(" [ args ] ")" ]   (* 字段访问 / 方法糖 *)
                       | "[" slice_or_index "]"           (* 下标 / 切片 *)
                       | "as" type } ;
slice_or_index = [ expr ] ":" [ expr ]                    (* 切片 s[a:b]/s[a:]/s[:b]/s[:] *)
               | expr ;                                   (* 下标 s[i] *)
call        = ident "(" [ args ] ")" ;                    (* len(x) 等内建 *)
```

## 4. 类型系统

- 基础类型：`int`(i32) `float`(f64) `bool`(i1) `str`(=`{ptr, len}` 字节切片，字面量带长) `u8/u16/u32/u64`
- 复合类型：`struct`（值语义）、`[N]T` 定长数组（长度前置 Go/Zig 式）、`fn(...) -> ret` 函数指针
- tuple：`(T1,T2,...)`，用于值、函数返回与 `let (a,b) = f()` 解构；不支持嵌套解构/下标，extern 禁止 tuple
- 系统层类型（§6）：`*T` 裸指针
- 内建：`len(x)`（str 返回运行时长度 i64，数组返回编译期长度）；切片 `s[a:b]`/`s[a:]`/`s[:b]`/`s[:]` 产生新 `str` 视图
- `str_from_ptr(ptr,len)` 从裸缓冲构造视图，`str_ptr(s)` 提取 `*u8`；二者都不转移或管理所有权

TODO：类型规则、隐式/显式转换、字面量类型。

## 5. safe 核心子集（默认，教学 + LLM 友好）

- 静态类型，值语义，无指针、无 GC、无隐式内存管理
- 变量（`let`）、函数、`if/else`、`while`、`struct`
- 只依赖 `stdlib/`，不接触裸内存

## 6. 系统子集（显式开启，OS 专用）

- `pointer` 类型 + 取址 / 解引用
- `volatile` 读写（MMIO）
- `asm { }` 内联汇编
- `unsafe { }` 块（危险代码显式标注）

## 7. 语义

- 词法作用域：函数体与每个 block 建立作用域；允许内层 shadowing，离开 block 后恢复外层绑定
- 条件：`if`/`while` 只接受 `bool`，整数必须显式比较（如 `x != 0`）
- 整数：`int` 是有符号 i32；`u8/u16/u32/u64` 的除法、余数和顺序比较使用无符号语义
- 求值顺序：表达式与函数实参从左到右求值（待增加更完整的规范示例）
- 调用约定：内部 aggregate（`str`/struct/tuple）交给 LLVM 目标 ABI；extern `str` 参数降为指针，extern 不得返回无长度的 `str`
- 切片：`0 <= lo <= hi <= len(s)`，违反边界时触发 trap
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

## 9. 待决项

- `string` 是否内建还是 std-lib 实现
