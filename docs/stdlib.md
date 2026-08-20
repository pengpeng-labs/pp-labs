# pp-lang 标准库（stdlib）

> 状态：**v0.3**。最小、自包含、部分自举（大部分用 `.pp` 写，仅少数 `extern` 到 libc 或裸机服务）。

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

当前 `string.pp` 已按切片长度实现 `strlen/strcmp`；`cstr_len(*u8)` 仅用于 FFI 边界。

## 内存与容器

| 文件 | API | 所有权 |
|------|-----|--------|
| `alloc.pp` | `alloc(n) -> *u8` / `dealloc(*u8)` | 调用方显式释放 |
| `buf.pp` | `buf_new/reserve/push/append/view/clear/free` | Buf 拥有 data；`buf_view` 仅借用视图 |
| `strmap.pp` | `map_new/set/get/has/del/free` | Map 拥有 key/value 副本；`map_get` 返回借用视图 |
| `vec.pp` | `vec_new[T]/push/get/free` | `Vec[T]` 拥有元素缓冲；调用方显式 `vec_free[T]` |

## 数学（math.pp）

| 函数 | 说明 |
|------|------|
| `abs(x)` / `max(a,b)` / `min(a,b)` | 基本 |
| `floor(x)` / `ceil(x)` | 取整 |

## 系统 / OS（sys.pp，Phase 5+）

| 函数 | 说明 |
|------|------|
| `alloc(n)` / `free(p)` | 显式分配器（bump，后置 free-list） |
| `outb(port, val)` / `inb(port)` | 端口 IO（MMIO） |

`str` 是内建切片；`Buf` 保留为字节协议缓冲，`Vec[T]` 提供通用同类型动态序列。
