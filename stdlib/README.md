# stdlib

pp-lang 的最小标准库：能用 `.pp` 自举的用 `.pp` 写，最底层原语走 `extern` 或编译器内置。

## 现状（Phase 4）

- **`math.pp`**：纯 `.pp` 自举（`abs` / `max` / `min`），演示 std-lib 用语言自己写。
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

## 规划（见 [docs/stdlib.md](../docs/stdlib.md)）

- `io.pp` / `string.pp` / `collection.pp`（可选）/ `sys.pp`（OS 专用，需系统层 pointer/volatile）
- 待语言支持系统层后再补齐字符串与 IO 的自举实现。
