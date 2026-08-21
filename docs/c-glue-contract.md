# ppos C Glue Contract

> 状态：PPOS-R2-5，2026-08。适用于 `boot/uip_glue.c`、`boot/tls_glue.c` 与 `boot/pp_glue.h`。第三方 uIP/BearSSL 源码保持只读；这里约束的是手写 glue 和 pplang wrapper。

## 1. 边界形状

```text
pplang service wrapper
  <-> pp_glue.h / handwritten C glue
  <-> read-only uIP or BearSSL
```

跨边界只允许：

- `int` / `int32_t`：长度、容量、端口、状态和错误码；
- `u32` / `uint32_t`：tick 等按位值；
- `u64` / native pointer：地址；
- `address + length`：只读 view；
- `address + capacity`：可写 buffer。

禁止把 C `char *` 声明成 pplang `str`。C 不理解 `{ptr,len}`；所有 callback 都在函数返回前完成消费，不能保存 pp 传入的地址。

## 2. 错误与失败原子性

| 值 | 名称 | 含义 |
|---:|---|---|
| `-1` | `PP_GLUE_EINVAL` | null、负长度、非法端口或未初始化设备 |
| `-2` | `PP_GLUE_EBUSY` | pending 空间暂时不足或发生重入 |
| `-3` | `PP_GLUE_EOVERFLOW` | 单个对象永远放不进目标容量，或接收数据已丢失 |

发送操作是 **all-or-nothing**：返回请求长度表示 glue 已复制全部输入；负值表示一个字节都没有消费。TLS 只有在返回值等于完整 record 长度后才能调用 BearSSL `sendrec_ack`。禁止部分复制后返回较短正数。

## 3. uIP 所有权

| 区域 | owner | 容量 | 生命周期 |
|---|---|---:|---|
| `tcp_pending` | uIP glue | 2048 B | connect/init 重置；按 MSS 分片发送 |
| `dns_pending` | uIP glue | 512 B | 收到响应、connect 或 init 时清除 |
| `rxbuf` | uIP glue | 16384 B | connect/init 重置；环绕复制，不允许线性尾部截断 |
| poll frame | uIP glue | 1600 B | 单次 `uip_glue_poll` |
| e1000 descriptor buffer | pp driver | 2048 B/slot | callback 期间借用 |

`pp_e1000_recv(dst,capacity)` 必须先比较 descriptor length，过大帧要归还 descriptor 并返回 `EOVERFLOW`，不能部分复制。`pp_e1000_send(src,length)` 同样拒绝超过 2048 B 的帧。

`pp_dns_recv`、`pp_dbg` 收到的地址属于 C/uIP，只在 callback 期间有效。pp 侧必须同步解析或复制；`pp_dbg` 使用显式长度，不扫描未知 NUL 结尾内存。

## 4. 回调与重入

`uip_glue_poll` 是单线程、不可重入状态机。它可以同步调用 e1000、DNS、debug callback，但 callback 不得再次调用 `uip_glue_poll/connect/send/recv`。重入返回 `EBUSY` 并记录 transport error。

IRQ 不直接进入 uIP/BearSSL。PIT 只更新 tick；shell/App 在普通执行上下文轮询。C glue 不阻塞、不 `hlt`、不分配内存；超时和让出策略属于 pplang service wrapper。

## 5. BearSSL 所有权

| 区域 | owner | 可用容量 | C 侧最低要求 |
|---|---|---:|---:|
| client context `0x660000` | TLS service | 4096 B | `sizeof(br_ssl_client_context)` |
| x509 context `0x661000` | TLS service | 4096 B | `sizeof(br_x509_minimal_context)` |
| bidirectional IO `0x663000` | TLS service | 49152 B | `BR_SSL_BUFSIZE_BIDI` |

`pp_tls_contract_check` 在目标架构上用 BearSSL 实际类型大小核验这些容量。所有 BearSSL pointer 参数和返回值在 pplang extern 中使用 `u64`。

known-key context 是 C glue 私有静态对象，因此 TLS 服务是单会话的。`pp_tls_session_begin/end` 保护整个 handshake/request/response 生命周期；第二个并发会话返回 `EBUSY`。无论握手、请求构造还是 transport 失败，wrapper 都必须结束已取得的 session。

当前验证策略仍是固定 RSA known-key，不是通用 CA 链验证；entropy 仍来自实验性 seed。这个合同保证内存和状态边界，不把当前 TLS 配置描述成通用生产安全方案。

## 6. 自动验收

`make test-glue-contract`：

- 用 freestanding cross compiler 和 `-Wall -Wextra -Werror` 编译两份 glue；
- 检查关键 pplang extern/callback 仍使用 `u64 + int length/capacity`；
- 检查合同、自测和 session guard 符号存在。

正常 QEMU smoke 在启动阶段执行 `glue_contract_selftest`，覆盖：

- TCP pending 填满后的 `EBUSY` 与失败原子性；
- null、负/超限容量错误；
- DNS 超过 512 B 时拒绝；
- BearSSL arena 实际大小；
- TLS 重入拒绝以及释放后可重新获取。

历史 DNS→TCP→TLS→HTTPS→DeepSeek tool-call 是网络端到端证据；默认 `make test` 使用 `-nic none`，验证的是确定性的 ABI、状态和容量合同，不依赖外部服务。
