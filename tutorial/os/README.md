# ppos 教程

ppos 教程 = 用 pp-lang 从零写 OS 的开发日志（对标 "Writing an OS in Rust"）。

语言：中英双语。

## 章节规划

- `00-freestanding.md`：无 libc 目标、自定义 `_start`、链接脚本
- `01-boot.md`：multiboot2 启动 + 长模式
- `02-console.md`：VGA / 串口输出
- `03-interrupts.md`：IDT + 键盘 + PIT
- `04-memory.md`：bump allocator
- `05-shell.md`：简单 shell

参考 `third_party/eggos/` 与 [os.phil-opp.com](https://os.phil-opp.com/)。

## 状态

未开始（Phase 5 起）。
