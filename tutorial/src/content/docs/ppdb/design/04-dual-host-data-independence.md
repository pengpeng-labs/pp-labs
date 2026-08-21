---
title: 4. 双宿主与数据独立性
description: 用 page/file provider 隔离数据库语义与运行环境。
---

数据库教材中的 data independence 通常区分逻辑 schema 与物理存储变化。ppdb 的双宿主进一步提出一个系统问题：同一存储和查询语义，能否运行在 POSIX 用户态和 freestanding ppos 中？

## 两组宿主接口

page provider：

```text
db_page_alloc()
db_page_ptr(page_no)
db_page_dirty(page_no)
db_page_free(page_no)
```

file provider：

```text
hf_create / hf_find
hf_write / hf_write_at
hf_read_at / hf_close
```

`db_core.pp` 只依赖 page contract，`db_persist.pp` 只依赖 file contract。native 与 ppos 各自提供同名实现，编译时选择对应模块。

## 两个宿主

| 能力 | native | ppos |
|---|---|---|
| 关系页区 | 64 KiB static buffer | 固定内存区域 |
| 文件 | POSIX open/read/write/lseek | ppos memory FS |
| 入口 | 独立 CLI executable | shell/app/MCP |
| libc | 可用 | 不存在 |
| 地址空间 | host process | 单地址空间 ring0/libos |

core 不应该知道文件描述符、inode、固定物理地址或 shell command。反过来，host provider 不应该重新解释 SQL、row layout 或 transaction。

## 这是 ports and adapters，也是可测试边界

接口把变化限制在外圈：数据库算法是 domain/core，宿主能力是 adapter。它不仅便于部署，也允许在 native 上快速运行完整测试，再把相同 core 链入 ppos。

但 native 通过不代表 ppos 自动正确。两个 adapter 仍需 contract tests，例如 page number 范围、free 后复用、short read、write offset 与 binary length。

## 固定容量为何适合 ppos

没有虚拟内存、成熟 allocator 和后台 IO worker 时，固定 page pool 让最坏资源占用可知。数据库满时返回失败，不在内核中无限增长。这个设计牺牲 scale，换取 bare-metal 环境下的确定性和可解释性。

课程后面会反复使用这条原则：先定义 core invariant，再分别验证两个 host 是否实现同一 contract。
