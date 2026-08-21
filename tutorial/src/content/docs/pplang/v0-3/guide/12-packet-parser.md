---
title: 综合实验：解析字节协议
description: 用 struct、str、Sum Type 和系统表示完成一条小型解析链路。
sidebar:
  order: 12
---

这一章不再引入新语法，而是组合前面学到的机制，解析一条极小的字节协议。

协议格式是：

```text
第 0 字节     kind
第 1 字节     ASCII 十进制长度（0~9）
其余字节      payload
```

例如 `A3ppp` 表示 kind 为 `A`、payload 长度为 3、内容为 `ppp`。

## 先设计合法状态

```pp
struct Packet {
    kind: u8,
    payload: str,
}

enum PacketResult {
    Ok(Packet),
    Error(str),
}
```

Packet 是积类型：kind 和 payload 同时存在。PacketResult 是和类型：解析要么成功并携带 Packet，要么失败并携带错误信息。

## 解析器

```pp
fn parse_packet(input: str) -> PacketResult {
    let n: int = len(input) as int;
    if (n < 2) {
        return PacketResult.Error("header too short");
    }

    let declared: int = input[1] as int - 48;
    if (declared < 0 || declared > 9) {
        return PacketResult.Error("invalid length");
    }
    if (n - 2 != declared) {
        return PacketResult.Error("length mismatch");
    }

    let packet: Packet = Packet {
        kind: input[0],
        payload: input[2:n]
    };
    return PacketResult.Ok(packet);
}
```

这里同时出现了：

- str 的长度和边界检查。
- u8 到 int 的显式转换。
- 严格 bool 条件。
- struct 组织成功结果。
- enum 组织互斥结果。
- 提前 return 缩短失败路径。

## 消费结果

```pp
fn packet_score(result: PacketResult) -> int {
    switch result {
        PacketResult.Ok(packet) {
            return packet.kind as int + len(packet.payload) as int;
        }
        PacketResult.Error(message) {
            println(message);
            return -1;
        }
    }
    return -1;
}
```

switch 必须覆盖两个状态。成功分支中的 `packet` 类型确定为 Packet，失败分支中的 `message` 类型确定为 str。

## 从书本知识到工程

| 知识点 | 在实验中的落点 |
|---|---|
| TAPL：积类型/和类型 | Packet 与 PacketResult |
| TAPL：静态类型判断 | u8、int、str 和返回类型检查 |
| PLAI：求值与错误路径 | 按字节读取、验证、构造结果 |
| CSAPP：数据表示 | ASCII 长度、字节索引、显式转换 |
| 组成原理：连续内存 | str 视图和半开区间切片 |
| Zig/Rust 工程经验 | 切片边界、tagged result 与责任可见 |

这就是整套教程希望建立的方法：不是先问“还可以增加什么语法”，而是从状态、表示、约束和失败路径出发，选择已有机制组合程序。

## 运行与扩展

完整示例位于 `tutorial/examples/pplang/packet_parser.pp`：

```sh
cd pplc
./target/debug/pp run ../tutorial/examples/pplang/packet_parser.pp
./target/debug/pp ir ../tutorial/examples/pplang/packet_parser.pp
```

继续完成三个扩展：

1. 允许 payload 长度为两位十进制数。
2. 增加 `Unsupported(u8)` 变体，并观察穷尽 switch 的诊断。
3. 将校验规则写成函数指针参数，再尝试为解析器增加显式泛型结果包装。

## 接下来

- 查准确规则：进入[参考手册](../reference/01-lexical-syntax/)。
- 看这些机制怎样实现：进入 pplc 教程或阅读 `pplc/src`。
- 看语言承担真实工作：ppdb 展示存储与查询，ppos 展示 freestanding 与硬件边界。

:::note[课程完成标准]
完成教程不只是能写出语法，而是能解释一个值的类型、表示、生命周期、失败状态和编译路径。遇到教程未覆盖的边角行为，先查 v0.3 规范，不按其他语言类推。
:::
