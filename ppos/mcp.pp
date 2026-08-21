/* mcp.pp：MCP（Model Context Protocol）——JSON-RPC 2.0 + 工具协议层。
   内部 MCP：pp-os 的工具以 MCP 规范注册/调用（tools/list、tools/call、initialize）。
   agent 通过本层调用工具；将来可桥接外部 MCP 服务器（网络版）。 */

/* ---- 工具注册表（MCP tools）---- */
static mcp_tool_name: [8]u64;
static mcp_tool_desc: [8]u64;
static mcp_tool_count: int = 0;
static mcp_method_buf: [64]u8;
static mcp_call_name_buf: [32]u8;
static mcp_sql_buf: [256]u8;
static mcp_key_buf: [128]u8;
static mcp_value_buf: [128]u8;
static mcp_op_buf: [64]u8;
static mcp_doc_name_buf: [128]u8;
static mcp_doc_content_buf: [128]u8;
static mcp_tool_result_buf: [3072]u8;

/* 注册工具（初始化时调用） */
fn mcp_register(name: str, desc: str) -> int {
    if (mcp_tool_count < 8) {
        mcp_tool_name[mcp_tool_count] = ptr_to_int(name);
        mcp_tool_desc[mcp_tool_count] = ptr_to_int(desc);
        mcp_tool_count = mcp_tool_count + 1;
        return mcp_tool_count - 1;
    }
    return -1;
}

/* 按名查找工具，返回 id；未找到 -1 */
fn mcp_find(name: u64) -> int {
    let i: int = 0;
    while (i < mcp_tool_count) {
        if (str_eq(mcp_tool_name[i], int_to_ptr(name)) == 1) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

/* 执行工具（id，req 为调用方传入的请求 JSON——工具参数从中提取），结果写入 out，返回长度 */
fn mcp_run_tool(id: int, req: u64, out: u64, out_cap: int) -> int {
    if (id == 0) {
        let listed: int = file_list_to_buffer(out, out_cap);
        if (listed < 0) { return mcp_emit(out, out_cap, "tool result too large\n"); }
        return listed;
    }
    /* sql 工具：参数 {"sql":"..."} */
    if (id == 1) {
        let sqlbuf: u64 = ptr_to_int(&mcp_sql_buf[0]);
        let sl: int = mcp_get_param_str(req, "sql", sqlbuf, 256);
        if (sl <= 0) {
            return mcp_emit(out, out_cap, "sql: missing or oversized sql param\n");
        }
        return database_execute_to_buffer(sqlbuf, out, out_cap);
    }
    /* kv 工具：参数 {"op":"get|put|del","key":"...","value":"..."} */
    if (id == 2) {
        let kbuf: u64 = ptr_to_int(&mcp_key_buf[0]);
        let vbuf: u64 = ptr_to_int(&mcp_value_buf[0]);
        let opbuf: u64 = ptr_to_int(&mcp_op_buf[0]);
        mcp_get_param_str(req, "op", opbuf, 64);
        let kl: int = mcp_get_param_str(req, "key", kbuf, 128);
        if (kl <= 0) {
            return mcp_emit(out, out_cap, "kv: missing or oversized key\n");
        }
        if (str_eq(opbuf, "get") == 1) {
            let value: ServiceBytes = database_kv_read(kbuf, out);
            if (!value.ok) {
                return mcp_emit(out, out_cap, "kv: not found\n");
            }
            if (value.len >= out_cap) { return mcp_emit(out, out_cap, "kv: result too large\n"); }
            volatile_store8(out + value.len, 0);
            return value.len;
        }
        if (str_eq(opbuf, "put") == 1) {
            if (mcp_get_param_str(req, "value", vbuf, 128) < 0) {
                return mcp_emit(out, out_cap, "kv: value too large\n");
            }
            if (database_kv_write(kbuf, vbuf)) {
                return mcp_emit(out, out_cap, "kv put ok\n");
            }
            return mcp_emit(out, out_cap, "kv full\n");
        }
        if (str_eq(opbuf, "del") == 1) {
            if (database_kv_remove(kbuf)) {
                return mcp_emit(out, out_cap, "kv del ok\n");
            }
            return mcp_emit(out, out_cap, "kv: not found\n");
        }
        return mcp_emit(out, out_cap, "kv: unknown op\n");
    }
    /* doc 工具：参数 {"op":"get|put","name":"...","content":"..."} */
    if (id == 3) {
        let nbuf: u64 = ptr_to_int(&mcp_doc_name_buf[0]);
        let cbuf: u64 = ptr_to_int(&mcp_doc_content_buf[0]);
        let opbuf2: u64 = ptr_to_int(&mcp_op_buf[0]);
        mcp_get_param_str(req, "op", opbuf2, 64);
        let nl: int = mcp_get_param_str(req, "name", nbuf, 128);
        if (nl <= 0) {
            return mcp_emit(out, out_cap, "doc: missing or oversized name\n");
        }
        if (str_eq(opbuf2, "get") == 1) {
            let document: ServiceBytes = database_doc_read(nbuf, out);
            if (!document.ok) {
                return mcp_emit(out, out_cap, "doc: not found\n");
            }
            if (document.len >= out_cap) { return mcp_emit(out, out_cap, "doc: result too large\n"); }
            volatile_store8(out + document.len, 0);
            return document.len;
        }
        if (str_eq(opbuf2, "put") == 1) {
            if (mcp_get_param_str(req, "content", cbuf, 128) < 0) {
                return mcp_emit(out, out_cap, "doc: content too large\n");
            }
            if (database_doc_write(nbuf, cbuf)) {
                return mcp_emit(out, out_cap, "doc put ok\n");
            }
            return mcp_emit(out, out_cap, "doc full\n");
        }
        return mcp_emit(out, out_cap, "doc: unknown op\n");
    }
    return mcp_emit(out, out_cap, "unknown tool");
}

/* ---- JSON-RPC 2.0 响应构建（写入 dst，返回长度）---- */

/* 成功响应：{"jsonrpc":"2.0","id":N,"result":R}
   result 为字符串时：{"result":"..."}；数字时：{"result":N} */
fn mcp_ok_string(dst: u64, dst_cap: int, id: int, result: u64) -> int {
    let writer: BoundedWriter = writer_new(dst, dst_cap);
    writer_write_str(&writer, "{\"jsonrpc\":\"2.0\",\"id\":");
    writer_write_int(&writer, id);
    writer_write_str(&writer, ",\"result\":\"");
    writer_write_json_cstr(&writer, result, dst_cap);
    writer_write_str(&writer, "\"}\n");
    if (!writer_terminate(&writer)) { return -1; }
    return writer.len;
}

/* 错误响应：{"jsonrpc":"2.0","id":N,"error":{"code":C,"message":"M"}} */
fn mcp_error(dst: u64, dst_cap: int, id: int, code: int, msg: str) -> int {
    let writer: BoundedWriter = writer_new(dst, dst_cap);
    writer_write_str(&writer, "{\"jsonrpc\":\"2.0\",\"id\":");
    writer_write_int(&writer, id);
    writer_write_str(&writer, ",\"error\":{\"code\":");
    writer_write_int(&writer, code);
    writer_write_str(&writer, ",\"message\":\"");
    writer_write_json_escaped(&writer, ptr_to_int(msg), len(msg) as int);
    writer_write_str(&writer, "\"}}\n");
    if (!writer_terminate(&writer)) { return -1; }
    return writer.len;
}

/* 从 JSON 请求提取 "id" 值（数字），返回 0 表示未找到 */
fn mcp_get_id(src: u64) -> int {
    let idv: int = 0;
    let i: int = 0;
    while (volatile_load8(src + i) != 0) {
        if (volatile_load8(src + i) == 34) {   /* '"' */
            if (volatile_load8(src + i + 1) == 105   /* 'i' */
                && volatile_load8(src + i + 2) == 100 /* 'd' */
                && volatile_load8(src + i + 3) == 34) {
                let j: int = i + 4;
                while (volatile_load8(src + j) != 58) {   /* ':' */
                    j = j + 1;
                }
                j = j + 1;
                while (volatile_load8(src + j) >= 48 && volatile_load8(src + j) <= 57) {
                    idv = idv * 10 + (volatile_load8(src + j) - 48);
                    j = j + 1;
                }
                return idv;
            }
        }
        i = i + 1;
    }
    return idv;
}

/* 从 JSON 请求提取 "method" 字符串值到 out，返回长度 */
fn mcp_get_method(src: u64, out: u64, out_cap: int) -> int {
    if (out_cap <= 0) { return -1; }
    let i: int = 0;
    while (volatile_load8(src + i) != 0) {
        if (volatile_load8(src + i) == 34) {   /* '"' */
            if (volatile_load8(src + i + 1) == 109 /* 'm' */
                && volatile_load8(src + i + 2) == 101 /* 'e' */
                && volatile_load8(src + i + 3) == 116 /* 't' */
                && volatile_load8(src + i + 4) == 104 /* 'h' */
                && volatile_load8(src + i + 5) == 111 /* 'o' */
                && volatile_load8(src + i + 6) == 100 /* 'd' */
                && volatile_load8(src + i + 7) == 34) {
                let j: int = i + 8;
                while (volatile_load8(src + j) != 58) {   /* ':' */
                    j = j + 1;
                }
                j = j + 1;
                while (volatile_load8(src + j) == 32) {
                    j = j + 1;
                }
                if (volatile_load8(src + j) == 34) {   /* '"' */
                    j = j + 1;
                    let o: int = 0;
                    while (volatile_load8(src + j) != 34 && o < out_cap - 1) {
                        volatile_store8(out + o, volatile_load8(src + j));
                        o = o + 1;
                        j = j + 1;
                    }
                    if (volatile_load8(src + j) != 34) {
                        volatile_store8(out + o, 0);
                        return -1;
                    }
                    volatile_store8(out + o, 0);
                    return o;
                }
            }
        }
        i = i + 1;
    }
    volatile_store8(out, 0);
    return 0;
}

/* 从 JSON 请求提取 "name" 参数值（params.name）到 out，返回长度 */
fn mcp_get_param_name(src: u64, out: u64, out_cap: int) -> int {
    if (out_cap <= 0) { return -1; }
    let i: int = 0;
    while (volatile_load8(src + i) != 0) {
        if (volatile_load8(src + i) == 34) {   /* '"' */
            if (volatile_load8(src + i + 1) == 110 /* 'n' */
                && volatile_load8(src + i + 2) == 97  /* 'a' */
                && volatile_load8(src + i + 3) == 109 /* 'm' */
                && volatile_load8(src + i + 4) == 101 /* 'e' */
                && volatile_load8(src + i + 5) == 34) {
                let j: int = i + 6;
                while (volatile_load8(src + j) != 58) {   /* ':' */
                    j = j + 1;
                }
                j = j + 1;
                while (volatile_load8(src + j) == 32) {
                    j = j + 1;
                }
                if (volatile_load8(src + j) == 34) {   /* '"' */
                    j = j + 1;
                    let o: int = 0;
                    while (volatile_load8(src + j) != 34 && o < out_cap - 1) {
                        volatile_store8(out + o, volatile_load8(src + j));
                        o = o + 1;
                        j = j + 1;
                    }
                    if (volatile_load8(src + j) != 34) {
                        volatile_store8(out + o, 0);
                        return -1;
                    }
                    volatile_store8(out + o, 0);
                    return o;
                }
            }
        }
        i = i + 1;
    }
    volatile_store8(out, 0);
    return 0;
}

/* 从 JSON 请求提取任意 "key":"value" 字符串到 out，返回长度（工具参数用；处理 \" \\ 转义） */
fn mcp_get_param_str(src: u64, key: str, out: u64, out_cap: int) -> int {
    if (out_cap <= 0) { return -1; }
    let i: int = 0;
    while (volatile_load8(src + i) != 0) {
        if (volatile_load8(src + i) == 34) {   /* '"' */
            let k: int = 0;
            let j: int = i + 1;
            while (key[k] != 0 && volatile_load8(src + j) == key[k]) {
                k = k + 1;
                j = j + 1;
            }
            if (key[k] == 0 && volatile_load8(src + j) == 34) {   /* key 后跟 '"' */
                j = j + 1;
                if (volatile_load8(src + j) == 58) {   /* ':' */
                    j = j + 1;
                    while (volatile_load8(src + j) == 32) {
                        j = j + 1;
                    }
                    if (volatile_load8(src + j) == 34) {   /* '"' */
                        j = j + 1;
                        let o: int = 0;
                        while (volatile_load8(src + j) != 34) {
                            if (o >= out_cap - 1) {
                                volatile_store8(out + out_cap - 1, 0);
                                return -1;
                            }
                            if (volatile_load8(src + j) == 92) {   /* '\' 转义 */
                                j = j + 1;
                                if (volatile_load8(src + j) == 34 || volatile_load8(src + j) == 92) {
                                    volatile_store8(out + o, volatile_load8(src + j));
                                    o = o + 1;
                                    j = j + 1;
                                    continue;
                                }
                                volatile_store8(out + o, 92);
                                o = o + 1;
                                continue;
                            }
                            volatile_store8(out + o, volatile_load8(src + j));
                            o = o + 1;
                            j = j + 1;
                        }
                        volatile_store8(out + o, 0);
                        return o;
                    }
                }
            }
        }
        i = i + 1;
    }
    volatile_store8(out, 0);
    return 0;
}

/* 把结果文本拷到 out（带换行），返回长度 */
fn mcp_emit(out: u64, out_cap: int, s: str) -> int {
    let writer: BoundedWriter = writer_new(out, out_cap);
    writer_write_str(&writer, s);
    if (!writer_terminate(&writer)) { return -1; }
    return writer.len;
}

/* 处理一个 JSON-RPC 请求：req 指向请求 JSON，resp 指向响应缓冲，返回响应长度 */
fn mcp_handle(req: u64, resp: u64, resp_cap: int) -> int {
    let id: int = mcp_get_id(req);
    let method: u64 = ptr_to_int(&mcp_method_buf[0]);
    let method_len: int = mcp_get_method(req, method, 64);
    if (method_len <= 0) {
        return mcp_error(resp, resp_cap, id, -32600, "invalid request");
    }
    if (str_eq(method, "initialize") == 1) {
        let info: str = "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"pp-os\",\"version\":\"0.7\"}}";
        return mcp_ok_string(resp, resp_cap, id, ptr_to_int(info));
    }
    if (str_eq(method, "tools/list") == 1) {
        let writer: BoundedWriter = writer_new(resp, resp_cap);
        writer_write_str(&writer, "{\"jsonrpc\":\"2.0\",\"id\":");
        writer_write_int(&writer, id);
        writer_write_str(&writer, ",\"result\":{\"tools\":[");
        let tool: int = 0;
        while (tool < mcp_tool_count && !writer.failed) {
            if (tool > 0) { writer_write_byte(&writer, 44); }
            writer_write_str(&writer, "{\"name\":\"");
            writer_write_json_cstr(&writer, mcp_tool_name[tool], 64);
            writer_write_str(&writer, "\",\"description\":\"");
            writer_write_json_cstr(&writer, mcp_tool_desc[tool], 512);
            writer_write_str(&writer, "\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
            tool = tool + 1;
        }
        writer_write_str(&writer, "]}}");
        if (!writer_terminate(&writer)) {
            return mcp_error(resp, resp_cap, id, -32000, "response too large");
        }
        return writer.len;
    }
    if (str_eq(method, "tools/call") == 1) {
        let name: u64 = ptr_to_int(&mcp_call_name_buf[0]);
        let name_len: int = mcp_get_param_name(req, name, 32);
        if (name_len <= 0) {
            return mcp_error(resp, resp_cap, id, -32602, "invalid params");
        }
        let tool_id: int = mcp_find(name);
        if (tool_id < 0) {
            return mcp_error(resp, resp_cap, id, -32602, "unknown tool");
        }
        let result: u64 = ptr_to_int(&mcp_tool_result_buf[0]);
        let result_len: int = mcp_run_tool(tool_id, req, result, 3072);
        if (result_len < 0) {
            return mcp_error(resp, resp_cap, id, -32000, "tool result too large");
        }
        let writer: BoundedWriter = writer_new(resp, resp_cap);
        writer_write_str(&writer, "{\"jsonrpc\":\"2.0\",\"id\":");
        writer_write_int(&writer, id);
        writer_write_str(&writer, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
        writer_write_json_escaped(&writer, result, result_len);
        writer_write_str(&writer, "\"}]}}");
        if (!writer_terminate(&writer)) {
            return mcp_error(resp, resp_cap, id, -32000, "response too large");
        }
        return writer.len;
    }
    return mcp_error(resp, resp_cap, id, -32601, "method not found");
}

/* Bounded in-process tool call used by the Agent and shell. */
fn mcp_call(name: u64, args: u64, result: u64, result_cap: int) -> int {
    let tool_id: int = mcp_find(name);
    if (tool_id < 0) {
        return mcp_emit(result, result_cap, "unknown tool");
    }
    return mcp_run_tool(tool_id, args, result, result_cap);
}
