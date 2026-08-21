---
title: 3. 多模型融合到了哪一层
description: 关系、KV 与 Doc 的统一生命周期及物理边界。
---

ppdb 应称为“多模型数据库”，不是“多模态数据库”。多模型指 relational、key-value、document 等数据模型；多模态通常指文字、图像、音频等 AI 输入形态。

## 为什么需要三种模型

同一 Agent session 中的数据有不同访问模式：

| 数据 | 主要操作 | 自然模型 |
|---|---|---|
| messages、统计、跨会话筛选 | 按列过滤、投影、排序愿景 | relation |
| current session、配置、游标 | 按 key 精确读写 | KV |
| 完整 context/tool-call JSON | 按名称整体存取 | Doc |

把所有内容放进一张 `key,value` 表会丢掉 schema 和关系查询；把每个配置都建关系表会增加不必要的 catalog/SQL 成本；把所有东西塞进 JSON 又会让过滤依赖应用层扫描。

多模型不是“功能越多越好”，而是让数据形态匹配主要访问路径。

## 当前统一程度

| 层次 | ppdb 当前设计 |
|---|---|
| 产品实例 | SQL、KV、Doc 属于一个 ppdb 状态 |
| 命令与 MCP | 一个 CLI/工具集合暴露三种接口 |
| transaction | before-image 同时覆盖 relation、KV、Doc |
| persistence | PDB4 同时保存三种模型和 index definition |
| host boundary | 共用 page/file provider 与 native/ppos 生命周期 |
| physical storage | relation 使用 heap pages；KV/Doc 使用固定数组 |
| query processing | SQL 只查询 relation，不跨模型 join |
| indexing | ordered index 服务关系表单列 INT |

所以准确表述是：**统一实例、事务与镜像下的多模型接口，物理结构和查询语言仍然模型特化。**

## 为什么没有强行统一物理存储

关系记录需要 schema、column offset、scan 和 row identity；小型 KV 需要有序 key 定位；Doc 当前只需整体 name→bytes。让三者都经过 heap tuple 会增加 metadata 和 code path，却没有给固定 KB 级场景带来明确收益。

未来若需要跨模型事务日志、统一缓存或更大容量，可以把 KV/Doc 也放入 page abstraction；那应由 workload 和 invariant 驱动，而不是为了让架构图看起来更统一。

## Doc 的诚实边界

Doc 层把 content 看作紧凑 JSON 或 bytes，不验证 JSON grammar，不做 field query、schema、index 或 partial update。MCP 负责 JSON-RPC envelope 的合法转义，不意味着存储层已经成为 MongoDB。

这条边界能避免 Agent 场景中常见的概念膨胀：能保存 JSON，不等于实现了 document database 的全部语义。
