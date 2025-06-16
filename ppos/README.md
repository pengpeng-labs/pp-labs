# pp-os

用 pp-lang 自己写的迷你 unikernel —— pp-lang 的 demo 与"压力测试"。

参考 `third_party/eggos/` 与 xv6 的功能清单，采用 **libos 式 unikernel** 理念：
单地址空间、无进程隔离、全部 ring0，OS 是一个链接进 `.pp` 程序的运行时库。

## 现状（v3 协程已跑通）

- ✅ multiboot v1 启动 + 32→64 位长模式转换
- ✅ VGA 文本输出（内存映射 `volatile_store16`）
- ✅ 串口输出（IO 端口 `outb`）
- ✅ IDT 中断（运行时构建）+ PIC 重映射
- ✅ PIT 定时器（IRQ0）+ 键盘（IRQ1 → 扫描码回显）
- ✅ bump allocator（`kmalloc`）+ `static` 全局变量
- ✅ 交互式 shell：行编辑 + `help`/`about`/`clear`/`echo` 命令
- ✅ 合作式协程（`switch_context`/`make_context`/`yield`）：shell 与心跳协程并发
- ⏳ 自旋锁、文件系统、抢占式调度

## 功能路线（结合 xv6 清单，unikernel 化）

| 里程碑 | 内容 |
|--------|------|
| **v0** | boot + VGA/串口输出 ✅ |
| **v1** | IDT 中断 + 键盘 + PIT 定时器 + bump allocator ✅ |
| **v2** | 简单 shell（行编辑 + 命令）✅ |
| **v3** | 合作式协程（shell + 心跳并发）✅ |
| **v4** | 自旋锁 + 内存文件系统（`ls/cat/write/rm`）✅ |
| v5 | 网络栈（NIC + TCP/IP + HTTP）|
| v6 | LLM 连接层（JSON + DeepSeek API）|
| v7 | agent + MCP + WASM 运行时 |

## 语言系统层（pp-lang 为此新增）

- `volatile_store8/16/32(addr, val)` / `volatile_load8/16/32(addr)` —— MMIO
- `outb(port, val)` / `inb(port)` —— 端口 IO（x86 out/in 指令）
- `cli` / `sti` / `hlt` —— 裸指令（开关中断、停机）
- `atomic_xchg(addr, val)` —— 原子交换（自旋锁）
- `int_to_ptr` / `ptr_to_int` —— 指针与 int 地址互转
- `&func` / `&x` / `*p` / `p[i]` / `p+i` —— 极简指针
- `u8/u16/u32/u64`、数组 `[T; N]`、字符串 stdlib、`static` 全局变量
