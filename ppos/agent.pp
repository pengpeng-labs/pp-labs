/* agent.pp：LLM agent——多轮对话 + 工具调用（DeepSeek function calling） */

/* 工具执行：走 MCP 协议层（mcp_call）；args 为工具参数 JSON（0x673300） */
fn agent_run_tool(name: u64, args: u64, out: u64, out_cap: int) -> int {
    return mcp_call(name, args, out, out_cap);
}

/* 从文件系统加载 API key 到 0x400600 */
fn agent_load_key() {
    let key_file: FileHandle = file_open("key");
    if (file_is_valid(key_file)) {
        file_read_all(key_file, 0x400600 as u64);
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

/* 主流程：text = 用户输入地址，tlen = 长度。
   循环 ≤3 轮：带 tools 请求 → 若有 tool_calls 则执行并回传，否则打印回答并持久化历史 */
fn agent_chat(text: u64, tlen: int) {    agent_load_key();
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
        /* 工具消息区（跨轮累积：assistant tool_calls + tool 结果）。 */
        let tool_messages: BoundedWriter = writer_new(0x676000 as u64, 2048);
        let round: int = 0;
        while (round < 3) {
            round = round + 1;
        /* 构建 body */
        let body: BoundedWriter = writer_new(0x66D000 as u64, 4096);
        writer_write_str(&body, "{\"model\":\"deepseek-chat\",\"messages\":[");
        /* 历史 */
        let hist_len: int = volatile_load32(0x675800);
        let history_size: int = hist_len;
        if (history_size > 1536) {
            history_size = 1536;
        }
        writer_write_bytes(&body, 0x675000 as u64, history_size);
        if (round == 1) {
            /* 第一轮：追加 user 消息，并存到 0x674000 供后续轮复用 */
            writer_write_str(&body, "{\"role\":\"user\",\"content\":\"");
            writer_write_json_escaped(&body, text, tlen);
            writer_write_str(&body, "\"},");
            let user_copy: BoundedWriter = writer_new(0x674000 as u64, 2048);
            writer_write_bytes(&user_copy, text, tlen);
            if (user_copy.failed) {
                console_write("DS: user message too large\n");
                return;
            }
            volatile_store32(0x674800, tlen);
        } else {
            /* 后续轮：历史 + user（0x674000）+ 累积的工具消息 */
            writer_write_str(&body, "{\"role\":\"user\",\"content\":\"");
            let ul: int = volatile_load32(0x674800);
            if (ul < 0 || ul > 2048) {
                console_write("DS: invalid saved user length\n");
                return;
            }
            writer_write_json_escaped(&body, 0x674000 as u64, ul);
            writer_write_str(&body, "\"},");
            let tool_size: int = tool_messages.len;
            if (tool_size > 1024) { tool_size = 1024; }
            writer_write_bytes(&body, tool_messages.data, tool_size);
        }
        /* 去掉 messages 数组的尾随逗号（历史/工具消息以 ',' 结尾） */
        if (body.len > 0 && volatile_load8(body.data + body.len - 1) == 44) {
            body.len = body.len - 1;
        }
        /* tools 定义（v1：ls + sql/kv/doc——pp-db 数据工具） */
        writer_write_str(&body, "],\"tools\":[");
        writer_write_str(&body, "{\"type\":\"function\",\"function\":{\"name\":\"ls\",\"description\":\"List files in the pp-os file system\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}},");
        writer_write_str(&body, "{\"type\":\"function\",\"function\":{\"name\":\"sql\",\"description\":\"Execute SQL against the pp-db database: CREATE TABLE, INSERT INTO, SELECT, UPDATE, DELETE, DROP TABLE\",\"parameters\":{\"type\":\"object\",\"properties\":{\"sql\":{\"type\":\"string\",\"description\":\"the SQL statement\"}},\"required\":[\"sql\"]}}},");
        writer_write_str(&body, "{\"type\":\"function\",\"function\":{\"name\":\"kv\",\"description\":\"Key-value store: get, put or delete a key\",\"parameters\":{\"type\":\"object\",\"properties\":{\"op\":{\"type\":\"string\",\"enum\":[\"get\",\"put\",\"del\"]},\"key\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"op\",\"key\"]}}},");
        writer_write_str(&body, "{\"type\":\"function\",\"function\":{\"name\":\"doc\",\"description\":\"JSON document store: get or put a named document\",\"parameters\":{\"type\":\"object\",\"properties\":{\"op\":{\"type\":\"string\",\"enum\":[\"get\",\"put\"]},\"name\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"op\",\"name\"]}}}],\"stream\":false}");
        if (body.failed) {
            console_write("DS: request body too large\n");
            return;
        }
        /* POST */
        let response: ServiceBytes = https_post(ptr_to_int(&dns_resolved[0]), 443, hst, "/v1/chat/completions", body.data, body.len);
        let rl: int = response.len;
        if (!response.ok) {
            return;
        }
        /* 定位 body */
        let hi: int = 0;
        let header_found: bool = false;
        while (hi < rl - 3) {
            if (volatile_load8(response.data + hi) == 13
                && volatile_load8(response.data + hi + 1) == 10
                && volatile_load8(response.data + hi + 2) == 13
                && volatile_load8(response.data + hi + 3) == 10) {
                header_found = true;
                break;
            }
            hi = hi + 1;
        }
        if (!header_found) {
            console_write("DS: invalid HTTP response\n");
            return;
        }
        let bstart: int = (response.data + hi + 4) as int;
        /* 解 chunked */
        let body_available: int = rl - (hi + 4);
        let jl: int = unchunk(bstart, body_available, 0x672000, 4095);
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
            let name_len: int = json_find_after(jsrc, "tool_calls", "name", 0x673100, 256);
            let id_len: int = json_find_after(jsrc, "tool_calls", "id", 0x673200, 256);
            let arg_len: int = json_find_after(jsrc, "tool_calls", "arguments", 0x673300, 256);
            if (name_len > 0 && id_len > 0) {
                /* 执行工具 */
                console_write("TOOL name=[");
                let tj2: int = 0;
                while (tj2 < name_len) {
                    console_putc(volatile_load8(0x673100 + tj2));
                    tj2 = tj2 + 1;
                }
                console_write("] args=[");
                tj2 = 0;
                while (tj2 < arg_len) {
                    console_putc(volatile_load8(0x673300 + tj2));
                    tj2 = tj2 + 1;
                }
                console_write("]\n");
                let res_len: int = agent_run_tool(0x673100, 0x673300, 0x673400, 3072);
                if (res_len < 0) {
                    console_write("DS: tool result too large\n");
                    return;
                }
                console_write("TOOL res=[");
                tj2 = 0;
                while (tj2 < res_len) {
                    console_putc(volatile_load8(0x673400 + tj2));
                    tj2 = tj2 + 1;
                }
                console_write("]\n");
                /* 组装 assistant(tool_calls) + tool(result) 追加到工具消息区 */
                writer_write_str(&tool_messages, "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"");
                writer_write_bytes(&tool_messages, 0x673200 as u64, id_len);
                writer_write_str(&tool_messages, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                writer_write_bytes(&tool_messages, 0x673100 as u64, name_len);
                writer_write_str(&tool_messages, "\",\"arguments\":\"");
                writer_write_json_escaped(&tool_messages, 0x673300 as u64, arg_len);
                writer_write_str(&tool_messages, "\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"");
                writer_write_bytes(&tool_messages, 0x673200 as u64, id_len);
                writer_write_str(&tool_messages, "\",\"content\":\"");
                writer_write_json_escaped(&tool_messages, 0x673400 as u64, res_len);
                writer_write_str(&tool_messages, "\"},");
                if (tool_messages.failed) {
                    console_write("DS: tool history too large\n");
                    return;
                }
            } else {
                console_write("DS: (tool call parse fail)\n");
                return;
            }
        } else {
            /* 无工具调用：打印 content */
            let cl: int = json_find_str(jsrc, "content", 0x673000, 256);
            if (cl > 0) {
                console_write("DS: ");
                let cj: int = 0;
                while (cj < cl) {
                    console_putc(volatile_load8(0x673000 + cj));
                    cj = cj + 1;
                }
                console_putc(10);
                /* 历史持久化：user + assistant */
                let history: BoundedWriter = writer_resume(0x675000 as u64, 2048, volatile_load32(0x675800));
                writer_write_str(&history, "{\"role\":\"user\",\"content\":\"");
                writer_write_json_escaped(&history, text as u64, tlen);
                writer_write_str(&history, "\"},{\"role\":\"assistant\",\"content\":\"");
                writer_write_json_escaped(&history, 0x673000 as u64, cl);
                writer_write_str(&history, "\"},");
                if (history.failed) {
                    console_write("DS: conversation history too large\n");
                    return;
                }
                volatile_store32(0x675800, history.len);
            } else {
                console_write("DS: (no content field)\n");
            }
            return;
        }
    }
    console_write("DS: (tool loop limit)\n");
}

/* ---- db ask：NL → 数据操作（P15-1）---- */

static db_ask_msgname: [32]u8;   /* "messages" 表名缓冲 */

/* 会话消息落库：messages(id int, role str, content str)——id 自增（kv 计数器 msgid）
   role/content 为字符串地址（int）；str 列定长 32B，超长截断 */
fn db_msg_log(role: int, content: int) {
    /* 确保 messages 表存在 */
    let table: DbTableHandle = database_table(0x407080 as u64);
    if (!database_table_is_valid(table)) {
        table = database_create(0x407080 as u64, 3, 0, 1, 1, 0);
        if (!database_table_is_valid(table)) {
            return;
        }
    }
    /* id = kv msgid 自增 */
    let midbuf: int = 0x407100;
    let counter: ServiceBytes = database_kv_read(0x407180 as u64, midbuf as u64);
    let midlen: int = counter.len;
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
    database_kv_write(0x407180 as u64, midbuf as u64);
    /* 插入 messages 行：id, role, content（地址即 u64 值） */
    let vals: [4]u64;
    vals[0] = mid;
    vals[1] = role;
    vals[2] = content;
    database_insert(table, ptr_to_int(&vals[0]));
}

/* db ask <问题>：预置含 schema 的 system 消息 → agent_chat（工具含 sql/kv/doc）→ 会话落库 */
fn db_ask(text: u64, tlen: int) {
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
    let history: BoundedWriter = writer_new(0x675000 as u64, 2048);
    writer_write_str(&history, "{\"role\":\"system\",\"content\":\"You are the pp-db assistant of pp-os. Database schema: ");
    database_write_schema(&history);
    writer_write_str(&history, ". Answer the question by calling the sql/kv/doc tools, then summarize the result.\"},");
    if (history.failed) {
        console_write("db ask: schema prompt too large\n");
        return;
    }
    volatile_store32(0x675800, history.len);
    /* 主循环（多轮工具调用） */
    agent_chat(text, tlen);
    /* 会话落库：user 问题（0x674000 稳定副本）→ messages；kv 状态 lastq */
    db_msg_log(0x407200, 0x674000);
    db_msg_log(0x407280, 0x673000);
    database_kv_write(0x407300 as u64, text);
    /* 会话 JSON 快照 → doc（128B 截断，v1 限制注明） */
    let hl: int = volatile_load32(0x675800);
    if (hl > 127) {
        hl = 127;
    }
    volatile_store8(0x675000 + hl, 0);
    database_doc_write(0x407380 as u64, 0x675000 as u64);
}
