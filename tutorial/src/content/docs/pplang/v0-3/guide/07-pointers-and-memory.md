---
title: 指针与显式内存
description: 裸指针、取址、解引用和 allocator 责任。
sidebar:
  order: 7
---

裸指针写成 `*T`。取址使用 `&value`，解引用使用 `*pointer`，字段和下标可以通过指针访问。

```pp
fn increment(value: *int) {
    *value = *value + 1;
}

let count: int = 4;
increment(&count);
```

指针支持判空、元素偏移和下标：

```pp
if (buffer != 0) {
    buffer[0] = 65;
}
```

需要同时表达“有值或无值”时，使用 `Option[*T]`；v0.3 不增加 `?*T` 语法。

## 分配与释放在库中

堆不是语言隐式能力。宿主程序通过 `stdlib/alloc.pp` 使用 allocator，ppos 则提供自己的 `kmalloc/kfree`。谁分配、谁释放仍是 API 契约，`defer` 只是让清理点更难遗漏。

## 为什么没有 unsafe block

v0.3 没有源码级 `unsafe {}`。当前编译器没有权限系统能让 block 内外的裸指针规则不同，加入关键字只会形成装饰。危险能力通过 `*T`、地址转换、volatile builtin 和模块边界直接可见。

普通应用代码优先使用 `str`、数组、struct 和标准库容器；裸指针留给 FFI、allocator、MMIO、DMA 与驱动边界。
