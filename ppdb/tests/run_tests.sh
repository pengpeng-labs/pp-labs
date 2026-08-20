#!/bin/bash
# pp-db 宿主机测试脚本（D-3）
# 用法：bash tests/run_tests.sh [ppdb 二进制路径]
# 步骤：
#   1. 编译 cli.pp → ppdb（或复用传入路径）
#   2. 跑 tests/cases.txt（golden 对比 expected.txt）
#   3. 跨进程持久化验证：进程 A 建库+save → 进程 B load → 数据一致
# 退出码：0 全过；1 失败（打印 diff）

set -u
cd "$(dirname "$0")/.."   # 到 ppdb/

PPDB="${1:-}"
if [ -z "$PPDB" ]; then
    echo "== 编译 cli.pp -> ppdb =="
    if ! ../pplc/target/debug/pp obj cli.pp -o /tmp/ppdb_test.o 2>/tmp/ppdb_build.err; then
        echo "FAIL: pp obj 编译失败"; cat /tmp/ppdb_build.err; exit 1
    fi
    if ! cc /tmp/ppdb_test.o -o /tmp/ppdb_test 2>>/tmp/ppdb_build.err; then
        echo "FAIL: cc 链接失败"; cat /tmp/ppdb_build.err; exit 1
    fi
    PPDB=/tmp/ppdb_test
fi

fail=0

echo "== 1. golden 测试（cases.txt vs expected.txt）=="
rm -f test.db
"$PPDB" < tests/cases.txt > /tmp/ppdb_out.txt 2>&1
if diff -u tests/expected.txt /tmp/ppdb_out.txt > /tmp/ppdb_diff.txt; then
    echo "PASS: golden 一致"
else
    echo "FAIL: golden 不一致（见下）"
    cat /tmp/ppdb_diff.txt
    fail=1
fi

echo "== 2. 跨进程持久化：save → 新进程 load =="
# 进程 A：建表 + 插入 + save
printf "sql CREATE TABLE persist (id int, name str)\nsql INSERT INTO persist (id,name) VALUES (1,'alice')\nsql INSERT INTO persist (id,name) VALUES (2,'bob')\nsql CREATE INDEX persist_id ON persist(id)\nsave persist.db\nquit\n" | "$PPDB" > /tmp/ppdb_save.txt 2>&1
# 进程 B：load + 校验
printf "load persist.db\nindexes\nsql SELECT id,name FROM persist WHERE id>=1\nquit\n" | "$PPDB" > /tmp/ppdb_load.txt 2>&1
if grep -q "db loaded (1 tables)" /tmp/ppdb_load.txt \
   && grep -q "persist_id persist.id" /tmp/ppdb_load.txt \
   && grep -q "1 alice" /tmp/ppdb_load.txt \
   && grep -q "2 bob" /tmp/ppdb_load.txt; then
    echo "PASS: 持久化往返一致"
else
    echo "FAIL: 持久化往返（save 输出 /tmp/ppdb_save.txt，load 输出 /tmp/ppdb_load.txt）"
    cat /tmp/ppdb_save.txt /tmp/ppdb_load.txt
    fail=1
fi

echo "== 3. 存储边界：第 128 页 + KV/Doc 满容量 =="
if ../pplc/target/debug/pp build tests/storage_bounds.pp -o /tmp/ppdb_storage_bounds \
   >/tmp/ppdb_bounds_build.txt 2>&1 \
   && /tmp/ppdb_storage_bounds; then
    echo "PASS: 存储边界一致"
else
    echo "FAIL: 存储边界（编译日志 /tmp/ppdb_bounds_build.txt）"
    cat /tmp/ppdb_bounds_build.txt
    fail=1
fi

echo "== 4. SQL 语义：列名映射 + 多字符串 + 非首列条件/更新 =="
if ../pplc/target/debug/pp build tests/sql_semantics.pp -o /tmp/ppdb_sql_semantics \
   >/tmp/ppdb_sql_build.txt 2>&1 \
   && /tmp/ppdb_sql_semantics >/tmp/ppdb_sql_out.txt 2>&1; then
    echo "PASS: SQL 列语义一致"
else
    echo "FAIL: SQL 列语义（编译日志 /tmp/ppdb_sql_build.txt）"
    cat /tmp/ppdb_sql_build.txt /tmp/ppdb_sql_out.txt
    fail=1
fi

echo "== 5. 损坏镜像：拒绝加载且保留当前数据库 =="
head -c 40 persist.db > truncated.db
printf "sql CREATE TABLE live (id int)\nsql INSERT INTO live (id) VALUES (9)\nload truncated.db\nsql SELECT id FROM live\nquit\n" \
    | "$PPDB" > /tmp/ppdb_invalid_load.txt 2>&1
if grep -q "load: invalid or truncated image" /tmp/ppdb_invalid_load.txt \
   && grep -q "^9$" /tmp/ppdb_invalid_load.txt; then
    echo "PASS: 损坏镜像不污染当前状态"
else
    echo "FAIL: 损坏镜像处理"
    cat /tmp/ppdb_invalid_load.txt
    fail=1
fi

rm -f test.db persist.db truncated.db

echo "== 结果：$([ $fail -eq 0 ] && echo ALL PASS || echo FAILED) =="
exit $fail
