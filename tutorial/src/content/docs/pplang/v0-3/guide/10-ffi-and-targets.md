---
title: FFI 与编译目标
description: extern、import、C 胶水和 hosted/freestanding 边界。
sidebar:
  order: 10
---

## import 是源码展开

```pp
import "../../../stdlib/vec.pp";
```

路径相对当前源文件解析。编译器递归加载导入文件，并按规范化路径去重。v0.3 没有 package manifest、依赖解析或 workspace 语义。

## extern 声明外部符号

```pp
extern fn puts(text: str) -> int;
extern fn printf(format: str, ... ) -> int;
```

extern 只描述 ABI，不提供实现。`pp run` 会在宿主进程中解析可用的 C 符号；`pp obj` 产生的目标文件由后续链接步骤解析符号。

`str` 在 extern 参数位置降为 C 指针。需要长度的 API 必须显式增加长度参数。extern 不能返回 `str`、tuple，也不能是泛型。

## 胶水模式

复杂 C 库和目标相关能力采用统一模式：交叉编译静态库、声明窄 extern 接口、在 C 胶水中适配复杂 ABI。ppos 的 uIP 和 BearSSL 都遵循这个边界。不要为了某个第三方头文件的形状扩展语言。

## hosted 与 freestanding

- `pp run/build/obj` 面向宿主环境，可以链接 libc。
- `pp os` 面向 x86_64 freestanding，不假设 libc 或操作系统。
- volatile、端口 IO、中断和时钟通过目标相关 builtin 暴露。
- v0.3 不提供 ARM64 target。

完整 hosted FFI 示例位于 `tutorial/examples/pplang/ffi.pp`。
