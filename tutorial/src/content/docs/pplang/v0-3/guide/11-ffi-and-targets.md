---
title: import、FFI 与编译目标
description: 组织多文件程序，穿过 ABI，并区分 hosted 与 freestanding。
sidebar:
  order: 11
---

前面的章节主要讨论语言内部。真实系统还需要组织多文件源码、调用外部库，并在“有操作系统”和“没有操作系统”两种环境生成代码。

## import 是源码组织，不是包管理

```pp
import "../../../stdlib/vec.pp";
```

路径相对当前源文件解析。pplc 递归加载导入文件，并按规范化路径去重。

v0.3 的 import 没有命名空间、可见性、manifest、版本选择、依赖下载或 workspace 语义。它解决的是“把源码组合进同一次编译”，不是完整工具链问题。

## extern 声明 ABI 契约

```pp
extern fn puts(text: str) -> int;
extern fn printf(format: str, ...) -> int;
```

extern 只声明外部符号怎样被调用，不提供实现。`pp run` 可从宿主进程解析 libc 符号；`pp obj` 生成的目标文件则由后续链接步骤解析符号。

CSAPP 将链接解释为多个目标文件之间的符号解析与重定位。对 pplang 程序员而言，extern 是源码层契约，链接器负责找到实现，但双方必须对参数表示和调用约定达成一致。

## str 和 aggregate 的边界必须收窄

内部函数可以按 LLVM 目标 ABI 传递 str、struct、tuple 和 enum。跨 extern 时采用更保守的规则：

- str 参数降为 C 指针；目标 API 需要长度时另传长度。
- extern 不返回无法恢复长度的 str。
- tuple 不进入 extern。
- 泛型声明与内部实例名不构成稳定 extern ABI。
- 复杂 struct/union 应通过 C 胶水转换为窄接口。

```pp
extern fn write(fd: int, data: *u8, len: u64) -> int;

fn write_view(fd: int, value: str) -> int {
    return write(fd, str_ptr(value), len(value));
}
```

## 胶水模式

ppos 接入 uIP 和 BearSSL 时采用统一方式：

```text
第三方 C 库
    ↓ 交叉编译静态库
C 胶水：隐藏宏、回调、复杂 struct 与平台差异
    ↓ 窄 extern ABI
pplang 代码
```

不要因为某个 C 头文件复杂，就为它增加语言特性。FFI 的价值恰恰是把外部复杂度隔离在边界。

## hosted 与 freestanding

| 目标 | 命令 | 环境假设 |
|---|---|---|
| JIT | `pp run` | 当前宿主进程，可解析部分 libc |
| 可执行文件 | `pp build` | 宿主 OS 与系统链接器 |
| 目标文件 | `pp obj` | 后续由使用者决定链接方式 |
| 裸机目标 | `pp os` | x86_64 freestanding，不假设 libc |

freestanding 程序需要自己提供入口、内存布局、输出和运行时支持。volatile、端口 IO、中断控制与时钟通过目标相关 builtin 或 C/汇编胶水暴露。

计算机组成原理解释为什么设备和启动过程具有目标差异；CSAPP 解释目标文件、链接和 ABI；pplang 的四种输出模式把这些知识放进同一个编译器入口。

## 动手实验

1. 运行 `tutorial/examples/pplang/ffi.pp`。
2. 使用 `pp obj` 生成目标文件，再用系统工具查看未解析 extern 符号。
3. 为一个需要 `(ptr,len)` 的 C 函数写 pp wrapper。
4. 比较 hosted 输出和 `pp os` 所需入口，列出 libc 原本替你完成的工作。

:::caution[ABI 错误通常能通过编译]
extern 声明写错参数位宽或返回类型时，pplc 无法读取 C 头文件替你证明一致。错误可能在链接后才表现为数据破坏，因此复杂边界必须集中、窄化并测试。
:::
