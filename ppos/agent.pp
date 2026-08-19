/* agent.pp：LLM agent——多轮对话 + 工具调用（DeepSeek function calling） */

/* 工具执行：走 MCP 协议层（mcp_call）；args 为工具参数 JSON（0x673300） */
fn agent_run_tool(name: int, args: int, out: int) -> int {
    return mcp_call(name, args, out);
}

/* 从文件系统加载 API key 到 0x400600 */
fn agent_load_key() {
    let kidx: int = fs_find("key");
    if (kidx >= 0) {
        fs_read(kidx, 0x400600);
    } else {
        let kd: str = "sk-REPLACE_WITH_REAL_KEY";
        let t0: int = 0;
        while (kd[t0] != 0) {
            volatile_store8(0x400600 + t0, kd[t0]);
            t0 = t0 + 1;
        }
        volatile_store8(0x400600 + t0, 0);
    }
}

/* 把 str 追加到 dst+dpos，返回新 dpos */
fn agent_append(dst: int, dpos: int, s: str) -> int {
    let i: int = 0;
    while (s[i] != 0) {
        volatile_store8(dst + dpos, s[i]);
        dpos = dpos + 1;
        i = i + 1;
    }
    return dpos;
}

/* 主流程：text = 用户输入地址，tlen = 长度。
   循环 ≤3 轮：带 tools 请求 → 若有 tool_calls 则执行并回传，否则打印回答并持久化历史 */
fn agent_chat(text: int, tlen: int) {    agent_load_key();
    /* ARP 解析网关 */
    let gw: [4]u8;
    gw[0] = 10;
    gw[1] = 0;
    gw[2] = 2;
    gw[3] = 2;
    /* ARP/DNS 由 uIP 处理（uip_arp_out 自动解析网关 MAC） */
    /* DNS 解析 api.deepseek.com（固定轮询，不依赖返回值——uIP 异步处理） */
    let hst: str = "api.deepseek.com";
    dns_query(hst);
    let ht2: int = 0;
    while (ht2 < 5000) {
        net_poll();
        hlt();
        ht2 = ht2 + 1;
    }
        /* 工具消息区（跨轮累积：assistant tool_calls + tool 结果），长度 @0x676800 */
        let tmsg_len: int = 0;
        let round: int = 0;
        while (round < 3) {
            round = round + 1;
        /* 构建 body */
        let body: int = 0x66D000;
        let bi: int = 0;
        bi = agent_append(body, bi, "{\"model\":\"deepseek-chat\",\"messages\":[");
        /* 历史 */
        let hist_len: int = volatile_load32(0x675800);
        let hj: int = 0;
        while (hj < hist_len && hj < 1536) {
            volatile_store8(body + bi, volatile_load8(0x675000 + hj));
            bi = bi + 1;
            hj = hj + 1;
        }
        if (round == 1) {
            /* 第一轮：追加 user 消息，并存到 0x674000 供后续轮复用 */
            bi = agent_append(body, bi, "{\"role\":\"user\",\"content\":\"");
            bi = json_escape(text, tlen, body, bi);
            bi = agent_append(body, bi, "\"},");
            let uj: int = 0;
            while (uj < tlen) {
                volatile_store8(0x674000 + uj, volatile_load8(text + uj));
                uj = uj + 1;
            }
            volatile_store32(0x674800, tlen);
        } else {
            /* 后续轮：历史 + user（0x674000）+ 累积的工具消息 */
            bi = agent_append(body, bi, "{\"role\":\"user\",\"content\":\"");
            let ul: int = volatile_load32(0x674800);
            bi = json_escape(0x674000, ul, body, bi);
            bi = agent_append(body, bi, "\"},");
            let tj: int = 0;
            while (tj < tmsg_len && tj < 1024) {
                volatile_store8(body + bi, volatile_load8(0x676000 + tj));
                bi = bi + 1;
                tj = tj + 1;
            }
        }
        /* 去掉 messages 数组的尾随逗号（历史/工具消息以 ',' 结尾） */
        if (bi > 0 && volatile_load8(body + bi - 1) == 44) {
            bi = bi - 1;
        }
        /* tools 定义（v1：ls + sql/kv/doc——pp-db 数据工具） */
        bi = agent_append(body, bi, "],\"tools\":[");
        bi = agent_append(body, bi, "{\"type\":\"function\",\"function\":{\"name\":\"ls\",\"description\":\"List files in the pp-os file system\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}},");
        bi = agent_append(body, bi, "{\"type\":\"function\",\"function\":{\"name\":\"sql\",\"description\":\"Execute SQL against the pp-db database: CREATE TABLE, INSERT INTO, SELECT, UPDATE, DELETE, DROP TABLE\",\"parameters\":{\"type\":\"object\",\"properties\":{\"sql\":{\"type\":\"string\",\"description\":\"the SQL statement\"}},\"required\":[\"sql\"]}}},");
        bi = agent_append(body, bi, "{\"type\":\"function\",\"function\":{\"name\":\"kv\",\"description\":\"Key-value store: get, put or delete a key\",\"parameters\":{\"type\":\"object\",\"properties\":{\"op\":{\"type\":\"string\",\"enum\":[\"get\",\"put\",\"del\"]},\"key\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"op\",\"key\"]}}},");
        bi = agent_append(body, bi, "{\"type\":\"function\",\"function\":{\"name\":\"doc\",\"description\":\"JSON document store: get or put a named document\",\"parameters\":{\"type\":\"object\",\"properties\":{\"op\":{\"type\":\"string\",\"enum\":[\"get\",\"put\"]},\"name\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"op\",\"name\"]}}}],\"stream\":false}");
        /* POST */
        let rl: int = https_post(ptr_to_int(&dns_resolved[0]), 443, hst, "/v1/chat/completions", body, bi);
        if (rl <= 0) {
            return;
        }
        /* 定位 body */
        let hi: int = 0;
        while (hi < rl - 3) {
            if (volatile_load8(0x670000 + hi) == 13
                && volatile_load8(0x670000 + hi + 1) == 10
                && volatile_load8(0x670000 + hi + 2) == 13
                && volatile_load8(0x670000 + hi + 3) == 10) {
                break;
            }
            hi = hi + 1;
        }
        let bstart: int = 0x670000 + hi + 4;
        /* 解 chunked */
        let jl: int = unchunk(bstart, 0x672000, 4096);
        let jsrc: int = 0x672000;
        if (jl < 0) {
            jsrc = bstart;
            jl = 0;
            while (volatile_load8(jsrc + jl) != 0 && jl < 2048) {
                jl = jl + 1;
            }
        }
        volatile_store8(jsrc + jl, 0);
        if (json_has_field(jsrc, "tool_calls") == 1) {
            /* 提取 tool_call 字段（必须在 "tool_calls" 之后找，避免匹配顶层 id） */
            let name_len: int = json_find_after(jsrc, "tool_calls", "name", 0x673100);
            let id_len: int = json_find_after(jsrc, "tool_calls", "id", 0x673200);
            let arg_len: int = json_find_after(jsrc, "tool_calls", "arguments", 0x673300);
            if (name_len > 0 && id_len > 0) {
                /* 执行工具 */
                serial_print("TOOL name=[");
                let tj2: int = 0;
                while (tj2 < name_len) {
                    serial_putc(volatile_load8(0x673100 + tj2));
                    tj2 = tj2 + 1;
                }
                serial_print("] args=[");
                tj2 = 0;
                while (tj2 < arg_len) {
                    serial_putc(volatile_load8(0x673300 + tj2));
                    tj2 = tj2 + 1;
                }
                serial_print("]\n");
                let res_len: int = agent_run_tool(0x673100, 0x673300, 0x673400);
                serial_print("TOOL res=[");
                tj2 = 0;
                while (tj2 < res_len) {
                    serial_putc(volatile_load8(0x673400 + tj2));
                    tj2 = tj2 + 1;
                }
                serial_print("]\n");
                /* 组装 assistant(tool_calls) + tool(result) 追加到工具消息区 */
                tmsg_len = agent_append(0x676000, tmsg_len, "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"");
                let tj: int = 0;
                while (tj < id_len) {
                    volatile_store8(0x676000 + tmsg_len, volatile_load8(0x673200 + tj));
                    tmsg_len = tmsg_len + 1;
                    tj = tj + 1;
                }
                tmsg_len = agent_append(0x676000, tmsg_len, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                tj = 0;
                while (tj < name_len) {
                    volatile_store8(0x676000 + tmsg_len, volatile_load8(0x673100 + tj));
                    tmsg_len = tmsg_len + 1;
                    tj = tj + 1;
                }
                tmsg_len = agent_append(0x676000, tmsg_len, "\",\"arguments\":\"");
                tmsg_len = json_escape(0x673300, arg_len, 0x676000, tmsg_len);
                tmsg_len = agent_append(0x676000, tmsg_len, "\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"");
                tj = 0;
                while (tj < id_len) {
                    volatile_store8(0x676000 + tmsg_len, volatile_load8(0x673200 + tj));
                    tmsg_len = tmsg_len + 1;
                    tj = tj + 1;
                }
                tmsg_len = agent_append(0x676000, tmsg_len, "\",\"content\":\"");
                tmsg_len = json_escape(0x673400, res_len, 0x676000, tmsg_len);
                tmsg_len = agent_append(0x676000, tmsg_len, "\"},");
            } else {
                serial_print("DS: (tool call parse fail)\n");
                return;
            }
        } else {
            /* 无工具调用：打印 content */
            let cl: int = json_find_str(jsrc, "content", 0x673000);
            if (cl > 0) {
                serial_print("DS: ");
                let cj: int = 0;
                while (cj < cl) {
                    serial_putc(volatile_load8(0x673000 + cj));
                    cj = cj + 1;
                }
                serial_putc(10);
                /* 历史持久化：user + assistant */
                let hist_len: int = volatile_load32(0x675800);
                hist_len = agent_append(0x675000, hist_len, "{\"role\":\"user\",\"content\":\"");
                hist_len = json_escape(text, tlen, 0x675000, hist_len);
                hist_len = agent_append(0x675000, hist_len, "\"},{\"role\":\"assistant\",\"content\":\"");
                hist_len = json_escape(0x673000, cl, 0x675000, hist_len);
                hist_len = agent_append(0x675000, hist_len, "\"},");
                volatile_store32(0x675800, hist_len);
            } else {
                serial_print("DS: (no content field)\n");
            }
            return;
        }
    }
    serial_print("DS: (tool loop limit)\n");
}

/* ---- db ask：NL → 数据操作（P15-1）---- */

static db_ask_msgname: [32]u8;   /* "messages" 表名缓冲 */

/* 会话消息落库：messages(id int, role str, content str)——id 自增（kv 计数器 msgid）
   role/content 为字符串地址（int）；str 列定长 32B，超长截断 */
fn db_msg_log(role: int, content: int) {
    /* 确保 messages 表存在 */
    let tid: int = db_find_table(int_to_ptr(0x407080));
    if (tid < 0) {
        tid = db_create_table(int_to_ptr(0x407080), 3, 0, 1, 1, 0);
        if (tid < 0) {
            return;
        }
    }
    /* id = kv msgid 自增 */
    let midbuf: int = 0x407100;
    let midlen: int = kv_get(0x407180, midbuf);
    let mid: int = 0;
    if (midlen > 0) {
        let mi: int = 0;
        while (mi < midlen) {
            mid = mid * 10 + (volatile_load8(midbuf + mi) - 48);
            mi = mi + 1;
        }
    }
    mid = mid + 1;
    /* 写回计数器 */
    let mtmp: [12]u8;
    let mi2: int = 0;
    let mm: int = mid;
    while (mm > 0) {
        mtmp[mi2] = 48 + (mm % 10);
        mm = mm / 10;
        mi2 = mi2 + 1;
    }
    let mi3: int = 0;
    while (mi2 > 0) {
        mi2 = mi2 - 1;
        volatile_store8(midbuf + mi3, mtmp[mi2]);
        mi3 = mi3 + 1;
    }
    volatile_store8(midbuf + mi3, 0);
    kv_put(0x407180, midbuf);
    /* 插入 messages 行：id, role, content（地址即 u64 值） */
    let vals: [4]u64;
    vals[0] = mid;
    vals[1] = role;
    vals[2] = content;
    db_insert(tid, ptr_to_int(&vals[0]));
}

/* db ask <问题>：预置含 schema 的 system 消息 → agent_chat（工具含 sql/kv/doc）→ 会话落库 */
fn db_ask(text: int, tlen: int) {
    /* 固定地址常量：messages 表名 / msgid 键 / user+assistant 角色 / lastq / session doc 名 */
    let mn: str = "messages";
    let mi: int = 0;
    while (mn[mi] != 0) {
        volatile_store8(0x407080 + mi, mn[mi]);
        mi = mi + 1;
    }
    volatile_store8(0x407080 + mi, 0);
    let mk: str = "msgid";
    mi = 0;
    while (mk[mi] != 0) {
        volatile_store8(0x407180 + mi, mk[mi]);
        mi = mi + 1;
    }
    volatile_store8(0x407180 + mi, 0);
    let r1: str = "user";
    mi = 0;
    while (r1[mi] != 0) {
        volatile_store8(0x407200 + mi, r1[mi]);
        mi = mi + 1;
    }
    volatile_store8(0x407200 + mi, 0);
    let r2: str = "assistant";
    mi = 0;
    while (r2[mi] != 0) {
        volatile_store8(0x407280 + mi, r2[mi]);
        mi = mi + 1;
    }
    volatile_store8(0x407280 + mi, 0);
    let mk2: str = "lastq";
    mi = 0;
    while (mk2[mi] != 0) {
        volatile_store8(0x407300 + mi, mk2[mi]);
        mi = mi + 1;
    }
    volatile_store8(0x407300 + mi, 0);
    let dn: str = "session";
    mi = 0;
    while (dn[mi] != 0) {
        volatile_store8(0x407380 + mi, dn[mi]);
        mi = mi + 1;
    }
    volatile_store8(0x407380 + mi, 0);
    /* 历史区重置为 system 消息（含全部表 schema） */
    let hist_len: int = 0;
    hist_len = agent_append(0x675000, hist_len, "{\"role\":\"system\",\"content\":\"You are the pp-db assistant of pp-os. Database schema: ");
    let sl: int = db_schema_to_buf(0x675000 + hist_len);
    hist_len = hist_len + sl;
    hist_len = agent_append(0x675000, hist_len, ". Answer the question by calling the sql/kv/doc tools, then summarize the result.\"},");
    volatile_store32(0x675800, hist_len);
    /* 主循环（多轮工具调用） */
    agent_chat(text, tlen);
    /* 会话落库：user 问题（0x674000 稳定副本）→ messages；kv 状态 lastq */
    db_msg_log(0x407200, 0x674000);
    db_msg_log(0x407280, 0x673000);
    kv_put(0x407300, text);
    /* 会话 JSON 快照 → doc（128B 截断，v1 限制注明） */
    let hl: int = volatile_load32(0x675800);
    if (hl > 127) {
        hl = 127;
    }
    volatile_store8(0x675000 + hl, 0);
    doc_put(0x407380, 0x675000);
}
