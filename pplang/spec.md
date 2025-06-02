# pp-lang 语言规范（spec）

> 状态：**草案 / 待填充（TODO）**。本文件是语言、教程第 0 章、以及喂给 LLM 的上下文三者的唯一权威来源。
> 约定：扩展名 `.pp`，编译器 `pp`。

## 1. 定位

一门"整个能装进脑子"的语言：小到能教编译原理，低到能写操作系统（freestanding），规整到 LLM 能可靠生成。

## 2. 词法（Lexical）

- 关键字（草案）：`fn` `let` `if` `else` `while` `return` `struct` `import` `extern` `unsafe` `asm` `true` `false`
- 标识符：`[A-Za-z_][A-Za-z0-9_]*`
- 字面量：整数 / 浮点 / 布尔 / 字符 / 字符串
- 注释：`//` 行注释，`/* */` 块注释
- 运算符：算术 / 比较 / 逻辑（优先级表见 §6）

TODO：补全精确 token 定义。

## 3. 语法（EBNF）

```ebnf
program     = { decl } ;
decl        = func_decl | struct_decl | import_decl | extern_decl ;
func_decl   = "fn" ident "(" [ params ] ")" [ "->" type ] block ;
params      = param { "," param } ;
param       = ident ":" type ;
struct_decl = "struct" ident "{" { field } "}" ;
block       = "{" { stmt } "}" ;
stmt        = let_stmt | if_stmt | while_stmt | return_stmt | expr_stmt ;
```

TODO：补全表达式层（`expr`/优先级）、`unsafe`/`asm`/系统层语法。

## 4. 类型系统

- 基础类型：`int` `float` `bool` `char` `string`
- 复合类型：`struct`（值语义）
- 系统层类型（§6）：`pointer`

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

- 作用域与可见性（TODO）
- 求值顺序（TODO）
- 调用约定（TODO）
- 内存模型：核心子集栈 + 值语义；堆仅在 std-lib 提供显式 allocator

### 已知编译器问题（待修）

1. **同名函数重定义**：同一编译单元内两个同名 `fn` 不会报错，而是都编译进同一个 LLVM 函数（第二个 body 追加到第一个之后，entry block 混乱）→ 调用行为不确定。编译器应报"重复定义"错误。规避：保持函数名唯一。
2. **variadic extern 参数错位**：extern 声明的函数类型硬编码 `is_var_arg=false`（codegen.rs `fn_type`）。调用真实 variadic 的 libc 函数（如 `open(const char*, int, ...)`）时，ARM64 上第 3 个及之后的参数（mode 等）传递错乱（实测 mode 丢失，文件权限异常）。规避：避免依赖 variadic 的第 3+ 参数；用非 variadic 替代（如 `fchmod` 补权限、`creat` 等）；或将来支持 `extern fn open(path: str, flags: int, ...)` 语法。

## 8. 目标产物

| 命令 | 产物 |
|------|------|
| `pp ir` | LLVM IR（`.ll`） |
| `pp build` | 可执行（用户态） |
| `pp obj` | 目标文件（`.o`） |
| `pp os` | freestanding 裸机 ELF |

## 9. 待决项

- `string` 是否内建还是 std-lib 实现
