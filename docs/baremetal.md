# pp-os 裸机部署设计文档

> pp-os 的两个真机目标平台 + 移植路线图。当前 pp-os 仅在 QEMU（x86_64）验证，
> 真机部署需要补齐硬件适配；本文件是裸机部署的唯一设计台账。

---

## 1. 背景与动机

pp-os 现状：x86_64 内核（multiboot v1 引导）、串口 + VGA 控制台、PS/2 键盘、
PIT/PIC、PCI e1000 网卡（QEMU 82540EM）、内存文件系统、DNS/TCP/HTTP/TLS（BearSSL）、
pp-db（RDB+KV+Doc）。

真机部署的两条线：

| 平台 | 架构 | 定位 |
|---|---|---|
| ThinkPad T430 | x86-64（Ivy Bridge） | 同架构真机验证，成本最低 |
| Raspberry Pi 4B 8GB | ARM64（Cortex-A72） | 独立移植线，展示跨架构能力 |

共性前置：**编译器地址模型 64 位化（方案B）**——RPi4 8GB 用满内存的硬前提，
同时消除宿主机（macOS/Linux）静态数据 >4GB 的地址截断。

---

## 2. 平台一：ThinkPad T430（x86-64）

### 2.1 硬件规格

| 项目 | 规格 |
|---|---|
| CPU | Intel Core i5-3320M（Ivy Bridge，2C/4T，2.6~3.3GHz） |
| 内存 | 8GB DDR3-1600 |
| 存储 | 500GB 7200RPM HDD（SATA，AHCI） |
| 显示 | 14" 1600×900 |
| 网卡 | Intel 82579LM（e1000e 家族，PCI 00:19.0） |
| 输入 | PS/2 内置键盘（走 EC，兼容 IRQ1 + 0x60） |
| 串口 | 无板载 COM（需底座/ExpressCard） |
| 系统 | Windows 7 Pro 64-bit（MBR/legacy 引导） |

### 2.2 引导链（沿用现有 multiboot 路径）

```
USB 启动 → GRUB legacy（BIOS 引导）→ multiboot v1 → kernel.elf
```

- pp-os 内核已是 multiboot v1 ELF（flags 0x3），GRUB `multiboot /kernel.elf` 直接可用
- **不需要磁盘驱动**：GRUB 负责把内核读入内存，FS 全在内存
- BIOS 设 legacy 引导（不碰 Windows 分区）；F12 选 U 盘
- ⚠️ GRUB 默认图形模式会接管显示 → 启动项需 `set gfxpayload=text`

### 2.3 现状差距（真机必踩）

| 差距 | 说明 | 优先级 |
|---|---|---|
| **无 VGA 文本输出** | 控制台全走串口（0x3F8），VGA 只清屏不写字 → 真机黑屏。T430 无串口，**必须**加 VGA 文本控制台（0xB8000，80×25，与串口双输出） | 🔴 致命 |
| **网卡型号差异** | 驱动针对 QEMU 82540EM；T430 是 82579LM。寄存器族兼容（EERD/RCTL/TCTL/描述符环），EEPROM/PHY 时序可能需真机调 | 🟡 中 |
| 无 RTC/CMOS 时钟 | agent/日志时间戳缺失 | 🟡 低（可选） |
| 内存映射 | 内核只用低 16MB，固定布局，不依赖 multiboot 内存信息 → 真机低风险 | 🟢 无 |

### 2.4 验收标准

1. U 盘 GRUB 引导进入 shell（VGA 显示、键盘输入）
2. `ls`/`app list`/`sql`/`db` 可用
3. 82579LM 网卡连通 → DNS/HTTP 可用（TLS 若受影响则降级）

---

## 3. 平台二：Raspberry Pi 4B 8GB（ARM64）

### 3.1 硬件规格

| 项目 | 规格 |
|---|---|
| SoC | Broadcom BCM2711 |
| CPU | 4 核 ARM Cortex-A72（ARMv8 / 64-bit，1.8GHz） |
| 内存 | 8GB LPDDR4-3200（低区 0x0 + 高区 0x400000000） |
| 存储 | MicroSD（FAT32 引导分区） |
| 网卡 | Gigabit Ethernet（GENET 控制器 + BCM54213PE PHY，内存映射 0xFD580000） |
| 视频 | 2× Micro-HDMI |
| 其他 | 40-pin GPIO、USB 3.0/2.0、Wi-Fi/BT（未列入首版） |
| 引导 | VideoCore GPU 固件从 SD 读 kernel8.img |

### 3.2 引导链（不走 multiboot）

```
上电 → BCM2711 启动 ROM → SD FAT32: start4.elf + fixup4.dat + config.txt
     → GPU 加载 kernel8.img 至 0x80000 → 跳转 ARM64
```

- config.txt：`arm_64bit=1`、串口 `enable_uart=1`
- kernel8.img = **raw binary**（非 ELF），入口固定 0x80000
- 引导本身不需要 pp-os 写 SD 驱动（GPU 固件代劳）；pp-db 持久化若要落 SD 需另行实现 EMMC2/SDHCI

### 3.3 现状差距（几乎全部驱动要重写）

| 差距 | 说明 | 优先级 |
|---|---|---|
| **编译器无 ARM 目标** | `pp os` 硬编码 x86_64-unknown-none；需新增 aarch64-unknown-none 目标 | 🔴 致命 |
| **x86 内联汇编内建** | `outb/inb/outl/inl`（端口 IO，RPi 无此概念）→ 全部改 MMIO 读写；`cli/sti/hlt` → DAIF/wfi；`rdtsc` → CNTPCT_EL0。`atomic_xchg` 用 LLVM atomicrmw，**平台无关** ✅ | 🔴 致命 |
| **无任何可用驱动** | 串口（PL011 @ 0xFE201000）、定时器（ARM 通用定时器）、中断（GIC-400 @ 0xFF841000）、网卡（GENET @ 0xFD580000）、键盘（无 PS/2，USB HID 需 USB 栈）全部从零 | 🔴 致命 |
| **启动桩重写** | aarch64 异常向量表 + EL1/EL2 切换 + MMU（或关 MMU 直跑物理地址） | 🔴 致命 |
| TLS 不可用（暂） | BearSSL 现编 x86_64；需 aarch64 交叉编译 libbearssl.a（libc.c/tls_glue.c 是纯 C 可跨编），否则 DeepSeek/TLS 全挂 | 🟡 中 |
| 显示/键盘（首版跳过） | 无 VGA 文本模式；HDMI 需帧缓冲（邮箱/固件接口）；USB 键盘需 HID 栈 | 🟡 首版可跳 |
| **8GB 内存利用** | 低 3GB + 高区 0x400000000；用满内存需 64 位地址 → **方案B 前置** | 🟡 后续 |

### 3.4 可复用资产（纯 pp，无需移植）

- 网络协议栈：TCP/UDP/ARP/DNS/IP 校验（net.pp 的协议层）
- HTTP/JSON/HTML 解析、agent（DeepSeek）、MCP、WASM
- pp-db 全部逻辑层（db_core/db_sql_*/db_kv/db_doc/db_persist）
- shell/FS（内存文件系统，地址常量重定位即可）

### 3.5 首版最小闭环

```
串口控制台（PL011）+ ARM 定时器 + GIC + GENET 网卡 + 现有网络栈 → ds/db/sql（串口输出）
```

### 3.6 验收标准

1. SD 卡 GPU 固件引导，串口出现 `PP-OS` + shell
2. 串口交互：`ls`/`app list`/`db` 命令可用
3. GENET 网卡连通 → DNS/HTTP 可用（TLS 交叉编译完成则 DeepSeek 可用）
4. 8GB 内存利用（方案B 完成后）：页池/FS 池扩容验证

---

## 4. 共用前置：编译器改造（方案B + ARM 目标）

| 项 | 内容 | 状态 |
|---|---|---|
| B-0 | `ptr_to_int` 返回 U64（去截断）+ 调用/返回点 coerce + `volatile_load64/store64` + `&func` 去截断 | ✅ 完成 |
| B-1 | 方案B 后 QEMU 全链路回归（P14-1~6，内核零行为变化验证）+ 宿主机 pp-db（P14-7） | ✅ 完成 |
| B-2 | `pp arm64 <file>`：triple=aarch64-unknown-none，产出 kernel8.img 所需目标文件 | 未开始 |
| B-3 | x86 内建 ARM 化：outb/inb/outl/inl→MMIO 别名、cli/sti/hlt→DAIF/wfi、rdtsc→CNTPCT_EL0 | 未开始 |

---

## 5. 里程碑

- [x] **B-0** 编译器地址模型 64 位化（方案B）
- [x] **B-1** QEMU 回归 + pp-db 宿主机宿主（P14-7 打通，验证方案B）
- [ ] **T-1** VGA 文本控制台（串口双输出）+ GRUB 引导镜像（gfxpayload=text）
- [ ] **T-2** T430 实机：legacy U 盘引导 → 键盘交互 → 82579LM 网卡适配
- [ ] **A-1** 编译器 ARM 目标 + x86 内建 ARM 化（B-2/B-3）
- [ ] **A-2** aarch64 启动桩 + kernel8.img + SD 卡布局（start4.elf/fixup4.dat/config.txt）
- [ ] **A-3** 驱动移植：PL011 串口 → ARM 定时器 → GIC → GENET
- [ ] **A-4** BearSSL 交叉编译（或降级 http-only）→ 网络栈验证
- [ ] **A-5** RPi4 实机引导（8GB 内存利用依赖方案B）

**顺序建议**：B-0 → B-1 → T-1/T-2（x86 真机，成本最低）→ A-1~A-5（ARM 独立线）。

---

## 6. 风险与边界

- ⚠️ T430 的 82579LM 与 QEMU 82540EM 的 EEPROM/PHY 差异是最大不确定点
- ⚠️ RPi4 无 PCI/PS/2/VGA 文本模式，驱动无法复用 x86 代码
- ⚠️ USB 键盘（RPi4）需完整 USB 主机栈，首版用串口规避
- ❌ 不做：Wi-Fi/BT、GPU 视频输出（首版）、SMP 多核
- ✅ 依赖：方案B 是 RPi4 8GB 与宿主机 pp-db 的共同前提，先做
