---
title: 源码与阶段地图
description: pplc v0.3 模块、入口、不变量与调试落点。
---

## 核心模块

| 文件 | 责任 | 主要入口 |
|---|---|---|
| `src/lexer.rs` | 字符到带位置 token | `tokenize` |
| `src/ast.rs` | `Type`、`Expr`、`Stmt`、`Item` | 数据定义 |
| `src/parser.rs` | token 到 AST | `Parser::parse_program` |
| `src/mono.rs` | 模板验证、替换、实例化与去重 | `monomorphize` |
| `src/sema.rs` | 名称、作用域、类型和穷尽检查 | `check_program` |
| `src/codegen.rs` | AST 到 LLVM module | `Codegen` |
| `src/main.rs` | import、流水线、JIT、目标发射与链接 | `load_program`、CLI commands |
| `tests/compiler.rs` | 黑盒语义与 IR 回归 | `cargo test` |

## 实际阶段顺序

`load_program` 是前端事实来源：

```text
read_file
  -> lexer::tokenize
  -> Parser::parse_program
  -> resolve_imports
  -> mono::monomorphize
  -> sema::check_program
```

随后 `codegen` 先声明命名类型，再声明 extern 和全部函数原型，接着声明 static，最后编译函数体。这种 two-pass declaration 支持前向函数调用。

## 常见问题从哪里查

| 现象 | 首先查看 |
|---|---|
| 字符或注释报错 | `lexer.rs` 的 `next_token` |
| 优先级/括号/初始化歧义 | `parser.rs` 的 `parse_binary`、`parse_postfix`、`parse_primary` |
| block 后变量仍可见 | `sema.rs` 和 `codegen.rs` 的作用域栈 |
| 泛型实例缺失或重复 | `mono.rs` 的 worklist、`mangle`、实例集合 |
| unsigned 行为错误 | `codegen.rs` 的 `compile_arith`、`compile_cmp` |
| struct/enum ABI 错误 | `declare_types`、`type_to_basic`、`storage_size` |
| JIT 能跑但 build 失败 | target triple、data layout、系统链接器和 extern ABI |

## 当前架构边界

pplc 没有独立 HIR/MIR，`typeof_expr` 与部分类型信息会在 sema 和 codegen 两处出现。这降低了阶段数量，却增加了保持两处一致的责任。若未来加入 source span 诊断、优化或多目标 ABI，最自然的演进是引入“已解析名称且完整带类型”的中间层，而不是继续扩大 AST 到 LLVM 的跨度。
