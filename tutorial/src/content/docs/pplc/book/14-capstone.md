---
title: 14. 综合实验：追踪 Packet Parser
description: 让一个网络协议小程序走过 pplc 的全部阶段。
---

综合实验使用 `tutorial/examples/pplang/packet_parser.pp`。它不是完整网络协议，却同时包含字节索引、长度、slice、struct、sum type、错误分支和穷尽 switch，足以让语言理论、编译前端与机器表示在一个程序中相遇。

协议约定很小：第 0 字节是 kind，第 1 字节是 ASCII 十进制长度，剩余内容是 payload。例如 `"A3ppp"` 合法，`"B4pp"` 声明长度与实际不符。

Kurose 与 Ross 的 top-down 方法从 application message 的语义开始，再逐层讨论 transport、network 与 link 如何承载它。这个实验也从 message format 开始，而不是先从 byte pointer 开始。编译器必须保留上层协议定义的三项约束：header 至少 2 bytes、length digit 合法、declared length 与剩余 payload 一致。

可以把 parser specification 写成 partial function：

```text
parse : ByteSlice -> Packet + ParseError
```

它对每个有限输入都应返回 `Ok(Packet)` 或 `Error(str)`，不能越界、悬空或落入没有结果的状态。和类型表达结果空间，bounds check 表达 memory safety 前提，二者共同实现这个 total behavior。

## 1. 建立源语义

`parse_packet` 返回 `PacketResult` 而不是 `-1` 或 null：

```pp
enum PacketResult {
    Ok(Packet),
    Error(str),
}
```

这把“成功值或错误信息”编码进类型。调用者必须通过穷尽 switch 处理两种情况。TAPL 的和类型在这里落成 API 约束，不是语法展示。

切片 `input[2:n]` 保留 `{address, len}`，不复制 payload；边界检查确保伪造长度不能制造越界 view。网络教材中的分层与健壮解析原则，在语言 runtime check 中获得具体支撑。

这里有三种不同的“长度”，必须避免混淆：slice runtime length `n`、协议 header 声明的 `declared`、成功 Packet 的 payload length。编译器只保证 slice bounds 和整数运算正确；`declared == n-2` 是应用层协议 invariant，由 pp 程序显式检查。

## 2. 画 AST 骨架

不必抄完整 Debug 输出，先手画关键结构：

```text
Function parse_packet
  If (n < 2)
    Return PacketResult.Error(...)
  Let declared = Cast(Index(input, 1), int) - 48
  If (...)
    Return PacketResult.Error(...)
  Let packet = StructInit Packet
    kind = Index(input, 0)
    payload = Slice(input, 2, n)
  Return PacketResult.Ok(packet)
```

检查 parser 是否把 `as int - 48` 结合为 `(input[1] as int) - 48`，并把 `input[2:n]` 识别为 Slice 而不是 Index。

用 PLAI 的表示方法检查一个更深的问题：AST 中 `Error("header too short")`、`Error("invalid length")`、`Error("length mismatch")` 结构相同，只是 data 不同；这说明错误分类目前由字符串承载。若以后需要机器可处理的错误类别，应演进 enum variant，而不是让 compiler 猜字符串内容。

## 3. 写下 sema 环境

进入 `parse_packet` 时：

```text
Γ0 = { input: str }
Γ1 = Γ0 + { n: int }
Γ2 = Γ1 + { declared: int }
Γ3 = Γ2 + { packet: Packet }
```

逐个证明 if condition 是 bool、Index(str) 得到 u8、cast 后可与 int 运算、Packet 字段类型匹配、每个 return 都是 PacketResult。

进入 `PacketResult.Ok(packet)` arm 时新增局部 `packet: Packet`；进入 Error arm 时新增 `message: str`。离开各 arm 后 binding 消失。两个 variant 全部覆盖，所以 switch 穷尽。

完整类型推导需要组合前面的规则：

```text
Gamma ⊢ input : str
Gamma ⊢ 1 : int
──────────────────── T-IndexStr
Gamma ⊢ input[1] : u8

Gamma ⊢ input[1] : u8    cast(u8,int) allowed
──────────────────────────────────────── T-Cast
Gamma ⊢ input[1] as int : int
```

随后 T-Sub 得到 `declared:int`。这棵 derivation 解释了为何 codegen 必须先读取 byte，再 zero-extend/cast，最后做 int subtraction。

## 4. 观察 LLVM IR

```bash
cd pplc
cargo build
./target/debug/pp ir ../tutorial/examples/pplang/packet_parser.pp > /tmp/packet.ll
rg 'define|icmp|switch|extractvalue|insertvalue|slice' /tmp/packet.ll
```

观察点：

- `Packet` 和 `PacketResult` 的 LLVM type；
- 每个 early return 的 basic block 与 terminator；
- slice 的三项 bounds predicate；
- enum tag 写入和 `switch i32`；
- payload address/field 的 GEP；
- `str` 的 address/length 提取与重组。

临时名称不重要，控制流和指令语义才重要。

把 IR 分成三层阅读：

1. representation：Packet、PacketResult、str 的 LLVM types；
2. data flow：index/load/cast/sub 与 payload address/length；
3. control flow：三个 validation branches、early returns、tag switch。

这对应龙书的 IR、组成原理的数据表示和 TAPL 的 elimination rule。综合实验的意义正是让三套理论在同一段 IR 中相遇。

## 5. 运行与破坏实验

```bash
./target/debug/pp run ../tutorial/examples/pplang/packet_parser.pp
```

程序会先为非法包打印 `length mismatch`，最后返回合法包分数 `68`。

依次做四次修改，每次先预测在哪个阶段失败：

1. 把 `if (n < 2)` 改成 `if (n)`：sema 应拒绝 int condition；
2. 删除 Error arm：穷尽检查应拒绝；
3. 把 `payload` 赋成 `input[0]`：struct field 类型检查应拒绝 u8/str 不匹配；
4. 强制构造 `input[2:99]`：编译成功，运行时 bounds check 触发失败路径。

这四个故障分别说明 parser 接受结构，不代表程序有类型；类型正确不代表所有输入都在安全边界内；编译期检查和运行时检查共同实现语言承诺。

再按协议等价类生成输入：空串、1-byte header、非数字 length、声明 0、恰好匹配、少一个 byte、多一个 byte、包含 NUL 的 payload。网络协议测试中的 boundary partitioning 与编译器的 bounds/type tests 在这里组成同一个验证矩阵。

## 6. 延伸任务

给协议增加二字节 big-endian 长度。先只用 `u8/u16` 和位运算实现，再检查 IR 中 extension、shift 和 unsigned comparison。随后把成功类型改成泛型 `Result[Packet, str]`（按当前语言已有的 enum 泛型写法），观察 mono 生成的具体 enum 名称与布局。

完成后，你应该能从一个源语言设计决定，一路追踪到 AST 节点、类型规则、LLVM instruction 和可观察运行行为。这正是 pplc Book 想建立的编译器思维。

## 7. 连接 ppdb 工作负载

packet parser 主要压力测试 byte/slice/sum/CFG；ppdb 则进一步压力测试 aggregate layout、generic containers、large whole-program monomorphization、POSIX FFI 和持久化。数据库教材中的 page、index、transaction invariant 不由 compiler 证明，但它们能放大 compiler 错误：一次错误的 struct offset 可能破坏 page，一次错误的 unsigned comparison 可能破坏索引顺序，一次错误的 FFI signature 可能破坏持久化。

因此真实项目不是“教材理论的装饰案例”，而是 compiler preservation 的外部观察器。前端与后端规则越准确，ppdb/ppos 中那些领域 invariant 才有可靠的执行基础。
