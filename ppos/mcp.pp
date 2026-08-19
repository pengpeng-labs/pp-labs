/* mcp.pp：MCP（Model Context Protocol）——JSON-RPC 2.0 + 工具协议层。
   内部 MCP：pp-os 的工具以 MCP 规范注册/调用（tools/list、tools/call、initialize）。
   agent 通过本层调用工具；将来可桥接外部 MCP 服务器（网络版）。 */

/* ---- 工具注册表（MCP tools）---- */
static mcp_tool_name: [8]int;   /* 工具名指针 */
static mcp_tool_desc: [8]int;   /* 工具描述指针 */
static mcp_tool_count: int = 0;

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
fn mcp_find(name: int) -> int {
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
fn mcp_run_tool(id: int, req: int, out: int) -> int {
    if (id == 0) {
        return fs_list_str(out);   /* ls */
    }
    /* sql 工具：参数 {"sql":"..."} */
    if (id == 1) {
        let sqlbuf: int = 0x401300;
        let sl: int = mcp_get_param_str(req, "sql", sqlbuf);
        if (sl == 0) {
            return mcp_emit(out, "sql: missing sql param\n");
        }
        let st: int = db_parse_sql(sqlbuf);
        if (st < 0) {
            return mcp_emit(out, "sql: syntax error\n");
        }
        /* db_parse_sql 返回 0=成功；语句类型在 db_stmt_type */
        if (db_stmt_type == 0) {
            /* CREATE：tid=-1 需建表 */
            let r: int = db_create_table(int_to_ptr(db_stmt_table), db_stmt_coln,
                db_stmt_types[0], db_stmt_types[1], db_stmt_types[2], db_stmt_types[3]);
            if (r >= 0) {
                return mcp_emit(out, "table created\n");
            }
            return mcp_emit(out, "create failed\n");
        }
        if (db_stmt_type == 5) {
            /* DROP */
            let tid5: int = db_find_table(int_to_ptr(db_stmt_table));
            if (tid5 >= 0) {
                db_drop_table(tid5);
                return mcp_emit(out, "table dropped\n");
            }
            return mcp_emit(out, "sql: no such table\n");
        }
        let tid: int = db_find_table(int_to_ptr(db_stmt_table));
        if (tid < 0) {
            return mcp_emit(out, "sql: no such table\n");
        }
        if (db_stmt_type == 2) {
            /* SELECT：结果写缓冲返回 */
            return db_select_to_buf(tid, out);
        }
        if (db_stmt_type == 1) {
            db_exec_insert(tid);
            return mcp_emit(out, "1 row inserted\n");
        }
        if (db_stmt_type == 3) {
            db_exec_update(tid);
            return mcp_emit(out, "updated\n");
        }
        if (db_stmt_type == 4) {
            db_exec_delete(tid);
            return mcp_emit(out, "deleted\n");
        }
        return mcp_emit(out, "sql: unsupported\n");
    }
    /* kv 工具：参数 {"op":"get|put|del","key":"...","value":"..."} */
    if (id == 2) {
        let kbuf: int = 0x401300;
        let vbuf: int = 0x401380;
        let opbuf: int = 0x401400;
        mcp_get_param_str(req, "op", opbuf);
        let kl: int = mcp_get_param_str(req, "key", kbuf);
        if (kl == 0) {
            return mcp_emit(out, "kv: missing key\n");
        }
        if (str_eq(opbuf, "get") == 1) {
            let rl: int = kv_get(kbuf, out);
            if (rl < 0) {
                return mcp_emit(out, "kv: not found\n");
            }
            volatile_store8(out + rl, 0);
            return rl;
        }
        if (str_eq(opbuf, "put") == 1) {
            mcp_get_param_str(req, "value", vbuf);
            if (kv_put(kbuf, vbuf) == 1) {
                return mcp_emit(out, "kv put ok\n");
            }
            return mcp_emit(out, "kv full\n");
        }
        if (str_eq(opbuf, "del") == 1) {
            if (kv_del(kbuf) == 1) {
                return mcp_emit(out, "kv del ok\n");
            }
            return mcp_emit(out, "kv: not found\n");
        }
        return mcp_emit(out, "kv: unknown op\n");
    }
    /* doc 工具：参数 {"op":"get|put","name":"...","content":"..."} */
    if (id == 3) {
        let nbuf: int = 0x401300;
        let cbuf: int = 0x401380;
        let opbuf2: int = 0x401400;
        mcp_get_param_str(req, "op", opbuf2);
        let nl: int = mcp_get_param_str(req, "name", nbuf);
        if (nl == 0) {
            return mcp_emit(out, "doc: missing name\n");
        }
        if (str_eq(opbuf2, "get") == 1) {
            let rl: int = doc_get(nbuf, out);
            if (rl < 0) {
                return mcp_emit(out, "doc: not found\n");
            }
            volatile_store8(out + rl, 0);
            return rl;
        }
        if (str_eq(opbuf2, "put") == 1) {
            mcp_get_param_str(req, "content", cbuf);
            if (doc_put(nbuf, cbuf) == 1) {
                return mcp_emit(out, "doc put ok\n");
            }
            return mcp_emit(out, "doc full\n");
        }
        return mcp_emit(out, "doc: unknown op\n");
    }
    let msg: str = "unknown tool";
    let i: int = 0;
    while (msg[i] != 0) {
        volatile_store8(out + i, msg[i]);
        i = i + 1;
    }
    volatile_store8(out + i, 0);
    return i;
}

/* ---- JSON-RPC 2.0 响应构建（写入 dst，返回长度）---- */

/* 成功响应：{"jsonrpc":"2.0","id":N,"result":R}
   result 为字符串时：{"result":"..."}；数字时：{"result":N} */
fn mcp_ok_string(dst: int, id: int, result: int) -> int {
    let o: int = 0;
    let h: str = "{\"jsonrpc\":\"2.0\",\"id\":";
    let i: int = 0;
    while (h[i] != 0) {
        volatile_store8(dst + o, h[i]);
        o = o + 1;
        i = i + 1;
    }
    o = o + itoa_buf(id, dst + o);
    let m: str = ",\"result\":\"";
    i = 0;
    while (m[i] != 0) {
        volatile_store8(dst + o, m[i]);
        o = o + 1;
        i = i + 1;
    }
    /* result 字符串转义拷贝 */
    let j: int = 0;
    while (volatile_load8(result + j) != 0) {
        let c: int = volatile_load8(result + j);
        if (c == 34) {
            volatile_store8(dst + o, 92);
            o = o + 1;
            volatile_store8(dst + o, 34);
            o = o + 1;
        } else {
            volatile_store8(dst + o, c);
            o = o + 1;
        }
        j = j + 1;
    }
    let t: str = "\"}\n";
    i = 0;
    while (t[i] != 0) {
        volatile_store8(dst + o, t[i]);
        o = o + 1;
        i = i + 1;
    }
    volatile_store8(dst + o, 0);
    return o;
}

/* 错误响应：{"jsonrpc":"2.0","id":N,"error":{"code":C,"message":"M"}} */
fn mcp_error(dst: int, id: int, code: int, msg: str) -> int {
    let o: int = 0;
    let h: str = "{\"jsonrpc\":\"2.0\",\"id\":";
    let i: int = 0;
    while (h[i] != 0) {
        volatile_store8(dst + o, h[i]);
        o = o + 1;
        i = i + 1;
    }
    o = o + itoa_buf(id, dst + o);
    let m: str = ",\"error\":{\"code\":";
    i = 0;
    while (m[i] != 0) {
        volatile_store8(dst + o, m[i]);
        o = o + 1;
        i = i + 1;
    }
    o = o + itoa_buf(code, dst + o);
    let m2: str = ",\"message\":\"";
    i = 0;
    while (m2[i] != 0) {
        volatile_store8(dst + o, m2[i]);
        o = o + 1;
        i = i + 1;
    }
    i = 0;
    while (msg[i] != 0) {
        volatile_store8(dst + o, msg[i]);
        o = o + 1;
        i = i + 1;
    }
    let t: str = "\"}}\n";
    i = 0;
    while (t[i] != 0) {
        volatile_store8(dst + o, t[i]);
        o = o + 1;
        i = i + 1;
    }
    volatile_store8(dst + o, 0);
    return o;
}

/* 从 JSON 请求提取 "id" 值（数字），返回 0 表示未找到 */
fn mcp_get_id(src: int) -> int {
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
fn mcp_get_method(src: int, out: int) -> int {
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
                    while (volatile_load8(src + j) != 34 && o < 64) {
                        volatile_store8(out + o, volatile_load8(src + j));
                        o = o + 1;
                        j = j + 1;
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
fn mcp_get_param_name(src: int, out: int) -> int {
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
                    while (volatile_load8(src + j) != 34 && o < 32) {
                        volatile_store8(out + o, volatile_load8(src + j));
                        o = o + 1;
                        j = j + 1;
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
fn mcp_get_param_str(src: int, key: str, out: int) -> int {
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
                        while (volatile_load8(src + j) != 34 && o < 200) {
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
fn mcp_emit(out: int, s: str) -> int {
    let i: int = 0;
    while (s[i] != 0) {
        volatile_store8(out + i, s[i]);
        i = i + 1;
    }
    return i;
}

/* 处理一个 JSON-RPC 请求：req 指向请求 JSON，resp 指向响应缓冲，返回响应长度 */
fn mcp_handle(req: int, resp: int) -> int {
    let id: int = mcp_get_id(req);
    let meth: int = 0x401000;
    let mlen: int = mcp_get_method(req, meth);
    if (mlen == 0) {
        return mcp_error(resp, id, -32600, "invalid request");
    }
    /* initialize */
    if (str_eq(meth, "initialize") == 1) {
        let s: str = "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"pp-os\",\"version\":\"0.7\"}}";
        return mcp_ok_string(resp, id, ptr_to_int(s));
    }
    /* tools/list */
    if (str_eq(meth, "tools/list") == 1) {
        let o: int = 0;
        let h: str = "{\"jsonrpc\":\"2.0\",\"id\":";
        let i: int = 0;
        while (h[i] != 0) {
            volatile_store8(resp + o, h[i]);
            o = o + 1;
            i = i + 1;
        }
        o = o + itoa_buf(id, resp + o);
        let m: str = ",\"result\":{\"tools\":[";
        i = 0;
        while (m[i] != 0) {
            volatile_store8(resp + o, m[i]);
            o = o + 1;
            i = i + 1;
        }
        let ti: int = 0;
        while (ti < mcp_tool_count) {
            if (ti > 0) {
                volatile_store8(resp + o, 44);   /* ',' */
                o = o + 1;
            }
            let t: str = "{\"name\":\"";
            i = 0;
            while (t[i] != 0) {
                volatile_store8(resp + o, t[i]);
                o = o + 1;
                i = i + 1;
            }
            let j: int = 0;
            while (volatile_load8(mcp_tool_name[ti] + j) != 0) {
                volatile_store8(resp + o, volatile_load8(mcp_tool_name[ti] + j));
                o = o + 1;
                j = j + 1;
            }
            let t2: str = "\",\"description\":\"";
            i = 0;
            while (t2[i] != 0) {
                volatile_store8(resp + o, t2[i]);
                o = o + 1;
                i = i + 1;
            }
            j = 0;
            while (volatile_load8(mcp_tool_desc[ti] + j) != 0) {
                volatile_store8(resp + o, volatile_load8(mcp_tool_desc[ti] + j));
                o = o + 1;
                j = j + 1;
            }
            let t3: str = "\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}";
            i = 0;
            while (t3[i] != 0) {
                volatile_store8(resp + o, t3[i]);
                o = o + 1;
                i = i + 1;
            }
            ti = ti + 1;
        }
        let t4: str = "]}}";
        i = 0;
        while (t4[i] != 0) {
            volatile_store8(resp + o, t4[i]);
            o = o + 1;
            i = i + 1;
        }
        volatile_store8(resp + o, 0);
        return o;
    }
    /* tools/call */
    if (str_eq(meth, "tools/call") == 1) {
        let name: int = 0x401100;
        let nl: int = mcp_get_param_name(req, name);
        if (nl == 0) {
            return mcp_error(resp, id, -32602, "invalid params");
        }
        let tid: int = mcp_find(name);
        if (tid < 0) {
            return mcp_error(resp, id, -32602, "unknown tool");
        }
        let result: int = 0x401200;
        let rl: int = mcp_run_tool(tid, req, result);
        /* 包装成 MCP 结果：{"result":{"content":[{"type":"text","text":"..."}]}} */
        let o: int = 0;
        let h: str = "{\"jsonrpc\":\"2.0\",\"id\":";
        let i: int = 0;
        while (h[i] != 0) {
            volatile_store8(resp + o, h[i]);
            o = o + 1;
            i = i + 1;
        }
        o = o + itoa_buf(id, resp + o);
        let m: str = ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"";
        i = 0;
        while (m[i] != 0) {
            volatile_store8(resp + o, m[i]);
            o = o + 1;
            i = i + 1;
        }
        let j: int = 0;
        while (j < rl) {
            let c: int = volatile_load8(result + j);
            if (c == 34) {
                volatile_store8(resp + o, 92);
                o = o + 1;
                volatile_store8(resp + o, 34);
                o = o + 1;
            } else {
                volatile_store8(resp + o, c);
                o = o + 1;
            }
            j = j + 1;
        }
        let t: str = "\"}]}}";
        i = 0;
        while (t[i] != 0) {
            volatile_store8(resp + o, t[i]);
            o = o + 1;
            i = i + 1;
        }
        volatile_store8(resp + o, 0);
        return o;
    }
    return mcp_error(resp, id, -32601, "method not found");
}

/* MCP 调用工具（供 agent 使用）：name 指向工具名，args 为参数 JSON（如 {"sql":"..."}，可 0），result 缓冲 */
fn mcp_call(name: int, args: int, result: int) -> int {
    let tid: int = mcp_find(name);
    if (tid < 0) {
        let msg: str = "unknown tool";
        let i: int = 0;
        while (msg[i] != 0) {
            volatile_store8(result + i, msg[i]);
            i = i + 1;
        }
        volatile_store8(result + i, 0);
        return i;
    }
    return mcp_run_tool(tid, args, result);
}
