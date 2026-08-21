---
title: 12. JIT、目标文件与 Freestanding
description: 同一 LLVM module 如何走向立即执行、系统链接与裸机对象。
---

pplc 有五个交付命令：`ir`、`run`、`obj`、`build`、`os`。它们共享前端和 codegen，但在 LLVM module 之后分叉。

## Object file 是什么

CSAPP 把 object file 解释为可重定位机器程序，而不是“还不能运行的可执行文件”。典型内容包括：

```text
.text       generated machine instructions
.rodata     string constants and read-only data
.data/.bss  initialized / zero-initialized globals
symbols     definitions and unresolved references
relocations places linker must patch
```

当函数调用外部 `puts` 时，pplc 不知道它最终地址。object 在 call site 留下 relocation，并记录 undefined symbol；linker 选择定义、布局 sections、计算地址并修补 relocation。

## `pp ir`

`ir` 打印 LLVM textual IR。它最适合学习和回归定位，不是最终产品格式。文本中应关注函数签名、target triple、aggregate layout、控制流和关键 signed/unsigned 指令。

## `pp run`

`run` 创建 LLVM JIT execution engine，在当前进程把 module 编译为机器码。extern declaration 通过 `dlsym` 解析到 libc 等宿主符号，随后以 Rust `unsafe extern "C" fn()` 类型取得 `main` 并调用。

这种模式启动快、适合测试，但与独立可执行程序共享当前进程的地址空间和动态库环境。错误的 JIT 函数签名是 Rust 类型系统无法检查的 FFI 风险。

JIT 与 ahead-of-time 的核心差别是“符号和地址何时确定”：JIT 在当前进程装载/编译 module 时解析，object 路径把 unresolved references 留给 linker/loader。二者共享 pp 前端语义，却有不同的 runtime trust boundary。

## `pp obj` 与 `pp build`

`obj` 初始化 LLVM targets，按宿主 triple 创建 `TargetMachine`，把 module 写成 `.o`。目标文件包含机器码、符号、section 和尚未解析的 relocation。

`build` 先发射临时 `.o`，再调用系统 `cc` 链接成可执行文件。这里复用 clang/gcc driver 的 startup objects、系统库搜索与平台链接参数，避免 pplc 自己成为链接器。

用系统工具观察边界：

```bash
./target/debug/pp obj ../examples/fib.pp -o /tmp/fib.o
file /tmp/fib.o
nm /tmp/fib.o
```

`nm` 展示 symbol table，`objdump`/`otool` 可查看 sections、relocations 与反汇编。把 `extern puts` 的 undefined symbol 与最终 executable 中的动态绑定对照起来，就能看到 CSAPP 的 linking model 在 pplc 产物中真实发生。

## `pp os`

`os` 请求 `x86_64-unknown-none`、static relocation 和 kernel code model，生成供 ppos 构建流程链接的 freestanding object。freestanding 意味着没有默认 libc、进程启动器或 OS syscall 合同；入口、内存、IO 和 runtime 由 ppos 提供。

OSTEP 和 CSAPP 在这里相接：同一段计算代码可以生成机器指令，但运行环境决定地址空间、启动状态、可用符号和设备访问方式。

OSTEP 所讲的 process abstraction 通常由 OS loader 建立 address space、stack、program entry 和 syscall interface。freestanding kernel 本身没有更下层 OS 来提供这些服务：boot code 决定入口状态，linker script 决定地址，ppos runtime 提供内存与 IO。编译器负责生成符合这份环境合同的 object，不能假设用户态进程条件存在。

## triple 与 data layout

Target triple 描述架构、vendor、OS/环境；data layout 描述 pointer size、endianness、alignment 等 ABI 事实。TargetMachine 则把这些信息和 CPU/features、relocation、code model 组合起来。

稳健的目标发射应在生成目标相关布局之前，把 module triple 和 target machine data layout 显式设为目标值，再运行 verifier。当前 v0.3 `Codegen::new` 默认写入宿主 triple，`emit_object_for_target` 则另外创建请求目标的 TargetMachine；x86_64 宿主到 x86_64-none 的现有路径可工作，但这是未来多架构前必须收紧的接口。

## 优化不是自动发生

JIT 和 TargetMachine 都使用 `OptimizationLevel::None`，pplc 没有自定义 pass pipeline。LLVM 后端仍会做生成机器码所需的合法化，但不要把它等同于源级/IR 优化。

教学上这是优点：`pp ir` 更接近 lowering 本身。要比较 SSA 形态，可把 IR 交给 LLVM `opt` 运行 mem2reg/标准优化，再观察 alloca/load/store 如何变化；任何优化都必须保持可观察语义。

## 交付链实验

对同一个 `fib.pp` 保存 IR、object symbol/relocation 列表和最终 executable 反汇编。为每一步写出仍未确定的信息：IR 尚未选择最终 registers，object 尚未确定外部 symbol 地址，executable 已完成静态布局但动态库 symbol 可能仍由 loader 解析。这样可以把“编译、汇编、链接、装载”四个常被混用的动作严格分开。
