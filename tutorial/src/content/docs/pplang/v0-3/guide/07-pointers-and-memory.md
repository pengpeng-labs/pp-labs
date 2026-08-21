---
title: 指针与显式内存
description: 从地址、解引用和连续内存走到 allocator 责任。
sidebar:
  order: 7
---

指针让程序直接引用内存位置。它是 pplang 能写 allocator、数据库页和设备驱动的基础，也是最容易越过类型系统保证的边界。

## 地址与所指类型

```pp
fn increment(value: *int) {
    *value = *value + 1;
}

let count: int = 4;
increment(&count);
```

- `&count` 取得地址，类型为 `*int`。
- `*value` 解引用地址，读取或写入 int。
- `*int` 告诉编译器怎样解释所指字节，但不证明地址有效。

CSAPP 中的虚拟地址、对象表示和访存指令在这里汇合：一次解引用最终会成为按特定位宽和对齐要求进行的 load/store。

## 判空、偏移与下标

```pp
if (buffer != 0) {
    buffer[0] = 65;
    buffer[1] = 66;
}
```

裸指针支持判空、元素偏移和下标。`buffer + 1` 按元素大小移动，不是永远增加一个字节。

判空只能排除地址 0，不能证明地址仍然存活、属于当前对象、满足对齐或拥有足够长度。需要范围时优先使用 str、数组或带长度的容器。

## 栈、静态区与堆

```text
局部变量       通常位于当前调用的栈存储
static         具有整个程序生命周期
allocator      返回显式管理的堆内存
MMIO 地址      由硬件平台定义
```

语言没有 GC 或自动析构。宿主程序通过 `stdlib/alloc.pp` 使用 allocator，ppos 提供自己的 `kmalloc/kfree`。

```pp
let data: *u8 = alloc(256);
if (data == 0) { return -1; }
defer dealloc(data);
```

谁分配、谁释放必须由 API 契约说明。`defer` 让清理靠近获取点，但仍可能发生重复释放、释放后使用或错误大小计算。

## 为什么没有 unsafe block

v0.3 没有 `unsafe {}`。当前语言没有权限系统能让 block 内外采用不同的指针规则；仅添加关键字会形成装饰。

危险能力通过以下事实保持可见：

- 类型中出现 `*T`。
- 代码使用地址转换或 volatile builtin。
- 模块位于 allocator、FFI、驱动或存储边界。

普通数据处理代码应优先使用值、str、数组、struct、enum 和标准库容器。

## 系统中的两类指针

### 普通内存

ppdb 的页提供者返回一页内存地址，存储内核按固定 header 和 slot 格式解释它。删除压缩后记录地址可能改变，因此索引保存稳定 row ID，而不是长期保存裸记录指针。

### 设备内存

ppos 的网卡与控制器通过 MMIO 或端口 IO 交互。设备寄存器不能被编译器当成普通内存随意消除、合并或缓存，因此需要 volatile builtin。

## 动手实验

1. 写一个交换两个 int 的 `swap(a: *int, b: *int)`。
2. 对 `[4]u8` 取得首元素地址，再用下标读取每个字节。
3. 用 `sizeof[T]()` 解释 `*T + 1` 的步长。
4. 阅读 ppdb 的 `db_page_ptr` 调用点，列出地址有效所依赖的三个条件。

:::note[理论落点]
组成原理和 CSAPP 解释地址、访存与设备；pplang 只提供足够直接的语言能力，不替程序证明生命周期和所有权。
:::
