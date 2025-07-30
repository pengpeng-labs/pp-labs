# pp-os 程序模型（App Model）

> "程序 = 协程 + 库"。**内核有边界**：内核 = 机制（fs/net/tls/json/协程/app 注册表）；应用 = 策略（browse/ds/sql/WASM 程序）。
> 本文档是边界契约：app 能调什么、怎么注册、生命周期如何。

---

## 1. 为什么要有边界

libos 式 unikernel 的边界不是"进程/用户态"，而是**服务接口（库 API）**：

```
内核（机制）提供【能力】：fs_read / net_send / tls_handshake / json_parse / 协程 / app_register
应用（策略）决定【行为】：浏览器怎么渲染、agent 何时调工具、SQL 怎么查询
边界契约 = 函数签名：app 只能通过库 API 触达内核资源
```

判断标准：**能复用的下沉为库/内核服务；某个程序专属的行为留在 app。**

## 2. 三层结构

```
┌────────────────────────────────────────────┐
│ 应用层（策略）——app                          │
│  browse   ds/agent   sql(pp-db)  WASM(未来)  │
├────────────────────────────────────────────┤
│ 应用框架（库，供 app import，也是策略）        │
│  browser 库（html_to_text 等）              │
│  agent 库（LLM 客户端 + 工具调用循环）        │
│  db 库（SQL 解析/执行/存储）                 │
├────────────────────────────────────────────┤
│ 内核服务（机制，pp-os 提供，有界）             │
│  fs / net / tls / json / 协程 / app 注册表   │
├────────────────────────────────────────────┤
│ 内核基础（boot/IDT/中断/串口/键盘/内存）       │
└────────────────────────────────────────────┘
```

## 3. App 注册表

```
app = { name, desc, id }          ← app.pp
注册：app_register(name, desc)    ← 编译期调用（id 与 app_dispatch 顺序一致）
运行：app run <name> → app_dispatch(id) → app 入口函数
参数：app 入口读 0x400200（shell 命令行缓冲）与 line_len
```

命令：`app list` / `app run <name>` / `app help <name>`

限制：编译器当前支持 `&func` 传参但无函数指针调用语法 → 注册表用 **id 分发**（libos 静态链接常态）。

## 4. 内核 API 清单（app 可用的公共接口）

### 存储
| 接口 | 说明 |
|---|---|
| `fs_init()` | 初始化 FS + 出厂默认文件 |
| `fs_find(name) -> idx` | 按名查文件 |
| `fs_create(name) -> idx` | 创建文件 |
| `fs_write(idx, data)` | 写内容（≤256B） |
| `fs_read(idx, buf) -> len` | 读内容到缓冲 |
| `fs_list()` / `fs_list_str(buf)` | 列出文件 / 列表字符串化 |
| `fs_remove(name)` | 删除 |

### 网络
| 接口 | 说明 |
|---|---|
| `arp_request(ip)` | 解析网关 MAC |
| `dns_query(host)` / `dns_resolved[]` | DNS 解析 |
| `net_poll()` | 收包轮询（处理 ARP/DNS/TCP） |
| `http_get_host(ip, port, host, path) -> len` | HTTP GET（HTTP/1.1 + Host 头），响应存 0x650000 |
| `https_post(ip, port, host, path, body, len) -> len` | HTTPS POST（TLS 1.2），响应存 0x670000 |

### 数据
| 接口 | 说明 |
|---|---|
| `unchunk(src, dst, max)` | HTTP chunked 解码 |
| `json_find_str(src, key, out) -> len` | JSON 字符串字段提取（含转义） |
| `json_find_after(src, marker, key, out)` | 从 marker 后提取（避开顶层同名字段） |
| `json_has_field(src, key)` | 判断字段存在 |
| `json_escape(src, len, dst, pos)` | JSON 字符串转义 |

### 系统
| 接口 | 说明 |
|---|---|
| `kmalloc(size)` / `kfree(ptr)` | free-list 分配器（16B 对齐） |
| `serial_print(s)` / `serial_putc(c)` / `print_int(n)` | 串口输出 |
| `hlt()` | 让出（定时器 100Hz，~10ms 粒度） |
| 协程：`make_context` / `switch_context` / `yield_` | 协作式调度 |

## 5. 生命周期

```
app run <name>
  → 查注册表 → app_dispatch(id) → 入口函数执行（同步，占住 shell）
  → 入口返回 → shell 恢复
```

- 无独立地址空间（unikernel）；栈 = 调用者栈（或未来独立协程栈）
- 网络 app（browse/ds）内部同步阻塞（轮询 + hlt）——单协程模型够用

## 6. WASM 演进（未来）

```
app 注册表条目不变；entry 从"编译期函数指针"变成"WASM 加载器 + 最小 WASI"
app install <file>：FS 里的 .wasm = 可装程序（unix"程序即文件"）
最小 WASI：print / fs_read / fs_write / net 子集
```

## 7. 注册表当前内容

| name | desc | 入口 |
|---|---|---|
| browse | CLI web browser (text render) | `browse_main` |
| ds | DeepSeek chat agent | `ds_main` |
| （未来）sql | pp-db 查询前端 | `sql_main` |
