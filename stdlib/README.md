# stdlib

pp-lang 的最小标准库：能用 `.pp` 自举的用 `.pp` 写，最底层原语走 `extern` 或编译器内置。

## 现状（Phase 4）

- **`math.pp`**：纯 `.pp` 自举（`abs` / `max` / `min`），演示 std-lib 用语言自己写。
- **`string.pp`**：按 `{ptr,len}` 切片语义实现字符串比较/拷贝，并隔离 C-string helper。
- **`alloc.pp`**：宿主显式 `*u8` 分配/释放边界。
- **`buf.pp`**：拥有内存的可增长字节缓冲。
- **`strmap.pp`**：拥有 key/value 副本的开放寻址哈希表。
- **`print` / `println`**：编译器内置（非 stdlib 文件），接受 `int` / `float` / `bool` / `str` 单个实参，底层调 libc `printf`。JIT（`pp run`）也会自动解析 extern 符号。
- **`import "path.pp";`**：相对当前文件展开，用于引入 stdlib。

## 使用

```pp
import "../stdlib/math.pp";

fn main() -> int {
    println(max(10, 20));
    return 0;
}
```

详细 API 与所有权约定见 [docs/stdlib.md](../docs/stdlib.md)。
