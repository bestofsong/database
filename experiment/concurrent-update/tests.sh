#!/usr/bin/env bash
set -e

cleanup() {
  # teardown things
  docker container stop testpg
  docker network rm testpgnet
  rm -rf datadir/*
}

if [ "${1:-}" = 'cleanup' ] ; then
  cleanup
  exit $?
fi

if [ ! -d datadir ] ; then
  mkdir datadir
fi
if ls datadir/* >/dev/null 2>&1 ; then 
  echo "datadir is not empty, not safe to continue."
  exit 1
fi
mkdir datadir/db

docker network create testpgnet
docker run --rm --name testpg -v "$(pwd)/datadir/db:/var/lib/postgresql/data" \
  --network testpgnet -d postgres:9-alpine

# wait pg to start
echo "wait for db to be ready.."
while ! docker run --rm --name testpgclient --network testpgnet postgres:9-alpine \
  psql -h testpg -U postgres -c '\h' >/dev/null 2>&1 ; do
  docker container rm testpgclient >/dev/null 2>&1 || true
  sleep 1
done

# init db
echo "init db, create db, table, etc"
init_sql='CREATE DATABASE testdb;'$'\n'\
'\c testdb;'$'\n'\
'CREATE TABLE testtbl (id INTEGER, value INTEGER);'$'\n'\
'INSERT INTO testtbl (id, value) VALUES (1, 0);'
echo "$init_sql" >datadir/init.sql
docker run --rm --name testpgclient --network testpgnet -v "$(pwd)/datadir/init.sql:/init.sql" \
  postgres:9-alpine psql -h testpg -U postgres -f '/init.sql'

# update
# 1, √ 单条update自增语句，并发事务不会冲突，会阻塞，等待的事务重新执行时会看到其他事务提交后的最新镜像，最终正常执行
update_sql1='UPDATE testtbl SET value = value + 1 WHERE id = 1;'
# 2, X 事务隔离级别改为可串行化，执行会报错ERROR:  could not serialize access due to concurrent update
update_sql2='SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL SERIALIZABLE;'$'\n'\
'UPDATE testtbl SET value = value + 1 WHERE id = 1;'
# 3, X 拆成read - write的反模式匿名函数，结果未报错，但是出现了数据错误
update_sql3='DO $$'$'\n'\
'DECLARE'$'\n'\
'  value_ INTEGER;'$'\n'\
'BEGIN'$'\n'\
'  SELECT value INTO STRICT value_ FROM testtbl WHERE id = 1;'$'\n'\
'  value_ := value_ + 1;'$'\n'\
'  UPDATE testtbl SET value = value_ WHERE id = 1;'$'\n'\
'END$$'
# 4, √ select for update, 行锁
update_sql4='DO $$'$'\n'\
'DECLARE'$'\n'\
'  value_ INTEGER;'$'\n'\
'BEGIN'$'\n'\
'  SELECT value INTO STRICT value_ FROM testtbl WHERE id = 1 FOR UPDATE;'$'\n'\
'  value_ := value_ + 1;'$'\n'\
'  UPDATE testtbl SET value = value_ WHERE id = 1;'$'\n'\
'END$$'
update_sql="$update_sql4"
echo "$update_sql" >datadir/update.sql
declare -a pids
declare -r NN=10
for ii in $(seq 0 $((NN - 1))) ; do
  docker run --rm --name "testpgclient${ii}" --network testpgnet -v "$(pwd)/datadir/update.sql:/test.sql" \
    postgres:9-alpine psql -d testdb -h testpg -U postgres -f '/test.sql' >/dev/null &
  pids[$ii]=$!
done

echo "waiting for transactions to finish.."
for pid in "${pids[@]}" ; do
  wait $pid
done

# check if value is right
docker run --rm --name testpgclient --network testpgnet \
  postgres:9-alpine psql -h testpg -U postgres -d testdb -c 'SELECT * FROM testtbl;'

cleanup
