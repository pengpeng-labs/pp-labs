---
title: 3. Import 与整程序视图
description: 路径解析、去重、前向声明与当前模块边界。
---

parser 每次只处理一个文件，但语义分析和单态化需要看到整个程序。`main.rs` 的 `resolve_imports` 在两者之间建立整程序视图。

```pp
import "../stdlib/string.pp";

fn main() -> int {
    return strlen("pp");
}
```

## 深度优先展开

入口文件先经过 lex/parse。遇到 `Item::Import(rel)` 时，编译器：

1. 相对当前文件目录拼接路径；
2. 用 `canonicalize` 得到规范路径；
3. 若已访问则跳过；
4. 读取、lex、parse 被导入文件；
5. 以被导入文件所在目录继续递归；
6. 将非 import item 追加到一个扁平列表。

规范路径去重解决了 `./a.pp` 与 `sub/../a.pp` 指向同一文件的问题，也让循环 import 不会无限递归。

从图论角度看，文件是 vertex，import 是 directed edge，入口文件的编译单元是从 root 可达的子图。`visited` 实现 graph traversal 的灰/黑集合简化版：当前实现只关心“是否处理过”，不区分正在访问与已经完成，因此循环依赖被去重，而不是诊断为 cycle。

龙书中的 symbol table 通常在作用域层次组织名称；import graph 则决定哪些声明进入同一次分析。两者不能混成一个概念：文件被访问一次不代表其所有顶层名称都合法，两个不同文件仍可能定义同名 symbol。

## 它不是什么

这不是 Cargo 式 package/module system。当前没有公开/私有可见性、包身份、版本解析、命名空间或独立编译单元；重复顶层名称最终由后续阶段处理。它更接近 C 的文本依赖与整程序编译之间的一种简化模型，但展开的是已解析 item，不是预处理文本。

这个边界适合 pp-labs：标准库、ppdb 和 ppos 可以拆文件，同时编译器仍能用全局视图做显式泛型单态化。

传统编译模型还区分 separate compilation 与 whole-program compilation。前者为每个 translation unit 生成 object，再由 linker 合并；后者让优化和实例化看到完整程序。pplc 的 import flattening 属于后者，所以单态化 worklist 能发现跨文件泛型调用，代价是任何依赖变化都要重新处理整个可达程序。

## 为什么先收集原型再编译函数体

codegen 不按源文件顺序立刻生成函数体，而是：

1. 声明 struct/enum 类型；
2. 声明 extern prototype；
3. 声明所有用户函数 prototype；
4. 声明 static；
5. 编译函数 body。

所以函数可以调用后面才定义的函数。LLVM module 中先存在 `FunctionValue`，生成 call 时就能引用它；函数体稍后再填入 basic block。

命名类型也需要先声明再填字段，才能表达指针递归结构。按依赖顺序组织 declaration pass，是后端构造图结构时常见的办法。

## 当前缺少的诊断

import 错误会报告无法解析或读取路径，但 AST 节点没有完整 source span，跨文件语义错误也不总能指出原文件。教程把这视为后续演进点：应让 source id + byte span 从 token 进入 AST/HIR，而不是在每层拼接字符串位置。

## 实验

创建 `a.pp` import `b.pp`，再让 `b.pp` import `a.pp`。编译应停止递归并继续处理每个 canonical file 一次。然后让两个文件定义同名函数，观察错误落在哪个阶段。这个实验能区分“依赖图去重”和“符号冲突检测”是两个不同职责。

再画出这两个文件的 import graph 与最终 item 顺序。改变 DFS 顺序后，合法程序的语义不应改变；如果改变了，说明某个后续阶段意外依赖 source traversal order，而不是依赖显式声明关系。
