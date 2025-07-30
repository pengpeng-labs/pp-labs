# pp-lang 标准库（stdlib）

> 状态：**草案 / 待定稿**。最小、自包含、部分自举（大部分用 `.pp` 写，仅少数 `extern` 到 libc 或裸机 VGA）。

## 原则

- 零依赖、自包含：AI 生成的 `.pp` 无需外部包即可跑
- 大部分自举：能用 `.pp` 写的就用 `.pp` 写
- `extern` 边界最小化：仅 `print` 等最底层原语

## IO（io.pp）

| 函数 | 说明 | 实现 |
|------|------|------|
| `print(x)` | 输出（无换行） | extern → libc `printf` / 裸机 VGA |
| `println(x)` | 输出 + 换行 | extern |
| `read()` | 读一行 | extern → libc / 串口 |

## 字符串（string.pp）

| 函数 | 说明 |
|------|------|
| `len(s)` | 长度 |
| `substr(s, i, n)` | 子串 |
| `concat(a, b)` | 拼接 |

## 数学（math.pp）

| 函数 | 说明 |
|------|------|
| `abs(x)` / `max(a,b)` / `min(a,b)` | 基本 |
| `floor(x)` / `ceil(x)` | 取整 |

## 集合（collection.pp，可选后置）

| 函数 | 说明 |
|------|------|
| `push(xs, x)` / `pop(xs)` / `get(xs, i)` | 数组 |

## 系统 / OS（sys.pp，Phase 5+）

| 函数 | 说明 |
|------|------|
| `alloc(n)` / `free(p)` | 显式分配器（bump，后置 free-list） |
| `outb(port, val)` / `inb(port)` | 端口 IO（MMIO） |

## 待决项

- `string` 内建类型 vs std-lib 结构体
- 数组语法与 `collection` 边界
