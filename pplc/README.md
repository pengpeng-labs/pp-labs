# pplc

`pp` 0.2.0 编译器：`.pp` 源码 → LLVM IR → 可执行 / JIT / 目标文件 / 裸机目标。

- 实现：**Rust + inkwell**（LLVM 18）
- 管线：`lexer → parser → AST → sema → codegen(IR)`

## 构建

依赖 LLVM 18（`brew install llvm@18`）。构建与运行所需路径已写入
[`.cargo/config.toml`](.cargo/config.toml)，直接：

```bash
cargo build
```

> 非 Apple Silicon macOS 请改 `.cargo/config.toml` 里的 LLVM 路径。

## 使用

```bash
pp ir    <file>            # 输出 LLVM IR
pp run   <file>            # JIT 执行 main 并打印返回值
pp build <file> [-o out]   # 编译并链接为可执行文件
pp obj   <file> [-o out]   # 生成宿主目标文件
pp os    <file> [-o out]   # 生成 freestanding x86_64 目标文件
```

示例：

```bash
./target/debug/pp ir    ../examples/fib.pp
./target/debug/pp run   ../examples/fib.pp     # -> 55
./target/debug/pp build ../examples/hello.pp -o hello
```

## 当前支持的语言子集

- 类型：`int`（i32）、`float`（f64）、`bool`、`str {ptr,len}`、`u8/u16/u32/u64`、`void`、
  `struct`、数组 `[N]T`、指针 `*T`、函数指针、受限 tuple `(T1,T2)`
- 表达式：整数/浮点/字符串字面量、变量、二元运算、一元 `- !`、函数调用、
  结构体构造/字段读写/指针接收者、数组下标、切片、显式 cast、函数与方法调用、tuple 值
- 语句：`let`（类型推断 + 零初始化）、赋值（含 `*p = v`、`buf[i] = v`）、
  `return`、表达式语句、严格 bool `if/else`/`while`、`for/in`、`defer`、tuple 解构
- 顶层：`fn` 定义、`extern` 声明、`struct` 声明、`import "file.pp"`、`static` 全局变量
- 内置：`print` / `println`（int/float/bool/str，单实参）；系统层 `volatile_store8/16/32`、
  `volatile_load8/16/32`、`outb`/`inb`、`cli`/`sti`/`hlt`、`int_to_ptr`/`ptr_to_int`

`pp run`（JIT）自动用 dlsym 解析 extern 函数（如 `printf`/`puts`）。extern 可以接收 `str`，
但不能返回缺少长度的 `str`；外部缓冲使用 `*u8`。

尚未支持：`unsafe/asm`、ARM64 裸机目标、Sum Type、`pp test` 子命令等（见
[`pplang/spec.md`](../pplang/spec.md) 与 [`docs/roadmap.md`](../docs/roadmap.md)）。

## 结构

```
src/
├── main.rs      # CLI（pp ir/run/build）
├── lexer.rs     # 词法分析
├── parser.rs    # 递归下降 + 优先级爬升
├── ast.rs       # AST 定义
├── sema.rs      # 名字、作用域与基础类型检查
└── codegen.rs   # AST → LLVM IR（inkwell）
```
