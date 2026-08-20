# pp-labs 教程站

同一个 Starlight 站点承载 pplang、pplc、ppdb、ppos 四套教程。当前完成 pplang v0.3 中文首版；英文路由使用中文内容回退。

## 本地开发

```bash
cd tutorial
npm ci
npm run dev
```

生产构建与教程示例验证：

```bash
npm run build
npm run check:examples
```

`check:examples` 默认使用 `pplc/target/debug/pp`，因此应先在 `pplc/` 执行 `cargo build`。也可以把其他编译器路径作为 `scripts/check_examples.sh` 的第一个参数。

内容位于 `src/content/docs/`，完整 `.pp` 示例位于 `examples/pplang/`。语言语义以仓库根目录的 `pplang/spec.md` 为准。
