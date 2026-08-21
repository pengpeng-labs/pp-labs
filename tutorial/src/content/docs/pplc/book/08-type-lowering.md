---
title: 8. 类型 Lowering 与内存布局
description: 标量、str、array、tuple、struct、enum 与递归类型如何进入 LLVM。
---

类型 lowering 要回答两个相关但不同的问题：一个值在 LLVM 中用什么类型表示，它在内存中需要多少空间和怎样对齐。`codegen.rs` 的 `type_to_basic` 与 `storage_size` 分别承担这些职责。

TAPL 关心一个类型允许哪些操作，组成原理与 CSAPP 关心这些值怎样落在 bit、byte、register 和 memory 中。lowering 是两者的连接函数：

```text
repr_target : SourceType -> LLVMType x Layout
```

它依赖 target，所以同一个 source struct 在不同 ABI 下可能有不同 padding；但它不能改变 source operation 的意义。

## 标量映射

| pplang | LLVM 典型表示 | 备注 |
|---|---|---|
| `bool` | `i1` | 只接受真正 bool 条件 |
| `u8` | `i8` | signedness 由指令决定 |
| `u16` | `i16` | 同上 |
| `int` / `u32` | `i32` | 源类型仍需保留 |
| `u64` | `i64` | 也用于地址相关整数 |
| `float` | `double` | 64 位浮点 |
| `*T` | `ptr` | LLVM 18 opaque pointer |

`void` 只能用于无返回值函数等非 first-class 位置，不能当作普通 load/store value。

组成原理中的补码解释了为什么 `int` 与 `u32` 能共享同一组 32 bits：bit pattern 不变，解释和 operation 不同。`0xffffffff` 作为 `u32` 是 4294967295，作为 `int` 是 -1。LLVM 因而让二者都使用 `i32`，把 signedness 放进 `sdiv/udiv` 和 `icmp slt/ult` 等指令。

## str 是 fat value

`str` 不是 NUL 结尾 `char*`，而是语义上的 `{address, len}`。当前 64 位地址模型将它 lowering 为两个 `i64` 字段：地址值和长度。这让切片可以共享底层字节而不复制，也让字符串内容可以包含 `\0`。相应地，FFI 到 C 字符串必须是显式边界转换，不能把 `str` 当裸指针传递。

## 聚合类型

- `[T, N]` lowering 为 LLVM array，长度是类型的一部分；
- tuple lowering 为按位置排列的匿名 struct；
- named struct 先创建 opaque named LLVM struct，再填充字段；
- enum lowering 为 tag + payload storage；
- `fn(A,B)->R` 需要函数签名，在作为值时以函数指针传递。

先声明 named type 再设置 body，允许：

```pp
struct Node {
    value: int,
    next: *Node,
}
```

`Node` 通过 pointer 间接递归是有限大小。若字段直接包含 `Node` 本身，storage size 递归永不结束，必须拒绝。`storage_size_inner` 使用 visiting set 检测这种非法无限布局。

## Alignment 与 padding

若字段 f 的对齐要求是 `align(f)`，当前 offset 必须先向上取整：

```text
aligned_offset = ceil(offset / align(f)) * align(f)
```

字段放入后更新 `offset += size(f)`；struct 最终大小还要向 struct 最大 alignment 取整。于是 `{u8, u64}` 通常不只是 9 bytes，中间可能有 7 bytes padding。

这些空隙对源语义不可见，却影响数组步长、GEP、FFI 和 object ABI。不能简单把字段 size 相加，也不能假设所有 target 的 u64 alignment 相同。

## size 不能只靠手算

字段 padding 和 alignment 取决于 target data layout。教学编译器可以用明确规则理解布局，但真正面向多目标时，应由 LLVM `TargetData` 计算 ABI size/alignment，并确保 module 设置了目标机器的数据布局。

这也是 `sizeof[T]`、`alignof[T]` 一类编译期能力的基础：泛型单态化后 T 已具体化，编译器才能得到目标相关常量。

endianness 是另一个 target fact：它决定多字节整数在连续地址中的 byte 顺序，不改变 LLVM `i32` 这个抽象值。packet parser 若手工组合网络 big-endian 字节，必须显式 shift/or；不能把 host memory 中的两个 bytes 直接当作 host-endian u16。这就是网络 workload 对 type/layout lowering 的实际压力。

## GEP 不是“加一个字节偏移”

`getelementptr` 根据聚合类型和索引计算地址：struct field index 选择字段，array index 按元素大小步进。它本身不读取内存，只生成派生地址。

对 `p.field`，后端先得到 `p` 的地址，再用 struct GEP 到字段；对 `a[i]`，需要 base、element type 与 index。opaque pointer 时代尤其不能丢掉 source aggregate type。

## 布局是一份 ABI 合同

同一个 struct 若在 pplang 与 C 胶水两侧布局不同，IR verifier 仍可能完全通过，但运行时会读错字段。跨语言结构、extern 函数、目标文件链接都要求调用双方共享宽度、对齐、参数传递与返回规则。类型 lowering 因而连接了 TAPL 的类型世界与 CSAPP 的机器表示世界。

## 表示保持实验

为一个包含 `u8/u64/str` 的 struct 写 pp 程序，打印 `sizeof`/`alignof`，再查看 LLVM named type。预测每个字段 offset 与 padding，然后用目标平台工具检查 object 的 data layout。理论预测、LLVM module 和实际 target 三者一致，才说明布局合同成立。
