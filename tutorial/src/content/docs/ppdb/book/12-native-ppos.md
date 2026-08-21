---
title: 12. 从 Native CLI 到 ppos
description: 同一数据库 core 如何适配 POSIX 进程和 freestanding unikernel。
---

双宿主不是复制两份数据库，而是替换最外层资源 provider。

```text
                      db_core / sql / index / tx / persist
                                  │
                 ┌────────────────┴────────────────┐
                 ▼                                 ▼
        native page/file                    ppos page/file
        static buffer + POSIX               fixed memory + mem FS
```

## Native 路径

`cli.pp` import native providers 与完整 core，通过 pplc 生成 object，再由系统 `cc` 链接 POSIX file symbols。产物是独立 `ppdb` executable，可跨进程 save/load。

native 路径承担三件事：证明 ppdb 不依赖 ppos、提供快速测试环境、验证 pplang/LLVM/FFI 在真实文件 API 上工作。

## ppos 路径

ppos 没有 libc process/file descriptor 环境。page provider 使用固定地址区域，file provider 适配 ppos memory FS；shell/app/MCP 在同一地址空间调用 core。

OSTEP 所讲的 process isolation 在这里不存在：database、Agent、network 和 kernel 共享故障域。固定 bounds、镜像预检和无动态增长策略因此不仅是教学简化，也是运行安全措施。

## Host contract

adapter 正确性至少包括：

- page allocation 只返回 `[0, DB_NPAGES)`；
- free page 可复用且不会双重分配；
- `db_page_ptr(n)` 对合法 n 返回稳定 page-sized region；
- read_at short read 被显式处理；
- write_at offset/length 不越过 file；
- binary bytes 不被 NUL 文本规则截断。

core test 全绿不能证明 adapter；应对 native 与 ppos provider 分别做 contract test。

## 为什么没有网络数据库 server

ppos 中的 consumer 都在同一系统，MCP 已是 Agent 的工具边界。再做数据库 TCP protocol 会引入 authentication、concurrency、framing 和 remote failure，却不增加存储原理价值。

Kurose & Ross 的网络分层知识用于理解 MCP/HTTPS transport，但数据库 core 不应依赖网络可达性。

## 构建路径

```bash
cd pplc && cargo build
cd ..
bash ppdb/tests/run_tests.sh
cd ppos && make
```

第一步验证编译器，第二步验证 native 完整语义，第三步验证 freestanding link/integration。故障应按层定位，而不是把所有问题都归为“数据库坏了”。
