# tools

- `ppdb-ref/`：pp-db 的 Rust 语义对照实现。运行 `cargo test --manifest-path tools/ppdb-ref/Cargo.toml`。

仓库级辅助工具目录（当前为空，占位）。

## 规划

- **extern 生成工具**（未开发）：从 C 头文件生成 `.pp` 的 extern 声明，减少手写
  `extern fn`（如 ppos 的 libc/BearSSL/uIP 胶水接口）的繁琐与出错。

## 说明

- 本目录只放**工具本身**，不涉及语言/编译器/OS/数据库本体。
- 工具形态未定：可以是脚本，也可以是 `.pp` 小程序，待需要时再定。
