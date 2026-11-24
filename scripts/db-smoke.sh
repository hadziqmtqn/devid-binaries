#!/bin/bash
# Smoke-test one database archive exactly as it ships (Devid D-058): unpack it into a fresh
# directory, create a data directory, start the server on 127.0.0.1 and a spare port, run a query
# with the bundled client, and stop it. Run it on the archive's own OS and arch.
#   scripts/db-smoke.sh <archive.tar.gz>
set -euo pipefail
ARCHIVE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NAME="$(basename "$ARCHIVE" .tar.gz)"
ENGINE="${NAME%%-*}"
# A spare port that stays clear of the usual 3306, 5432 and 27017 (servers on this machine keep them).
PORT="${SMOKE_PORT:-$((40000 + RANDOM % 20000))}"
T="$(mktemp -d "${TMPDIR:-/tmp}/db-smoke.XXXXXX")"
PID=""
stop() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap stop EXIT
fail() { echo "FAIL: $NAME: $*" >&2; [ -f "$T/log" ] && tail -40 "$T/log" >&2; exit 1; }
# On Linux with gdb, run a command that failed again under gdb, for the backtrace of a crash.
trace() {
  [ "$(uname -s)" = Linux ] && command -v gdb > /dev/null || return 0
  gdb -q -batch -ex run -ex bt --args "$@" 2>&1 | tail -30 >&2 || true
}
# The archive is unpacked under a path that is not where it was built, so a hard-coded path shows.
mkdir -p "$T/moved/here" && tar -xzf "$ARCHIVE" -C "$T/moved/here"
D="$T/moved/here"
# On Linux, the bundled libraries must be the ones loaded: ldd_from <dir> <binary> <soname...>
# (with LIBS set, as LD_LIBRARY_PATH).
ldd_from() {
  [ "$(uname -s)" = Linux ] || return 0
  local dir bin="$2" lib map path
  dir="$(readlink -f "$1")"
  shift 2
  map="$(env ${LIBS:+LD_LIBRARY_PATH="$LIBS"} ldd "$bin")" || fail "ldd $bin"
  ! grep -q 'not found' <<<"$map" || fail "$(basename "$bin") lacks libraries: $(grep 'not found' <<<"$map" | tr -s ' \t' ' ')"
  for lib in "$@"; do
    path="$(awk -v l="$lib" '$1 == l {print $3}' <<<"$map")"
    [ -n "$path" ] && [ "$(readlink -f "$path")" = "$dir/$lib" ] ||
      fail "$(basename "$bin") loads $lib from ${path:-nowhere}, not $dir"
  done
}
wait_for() { for _ in $(seq 60); do eval "$1" && return 0; kill -0 "$PID" 2>/dev/null || return 1; sleep 1; done; return 1; }

case "$ENGINE" in
  mysql)
    ldd_from "$D/lib/private" "$D/bin/mysqld" libaio.so.1 libnuma.so.1
    ldd_from "$D/lib/private" "$D/bin/mysql" libncurses.so.6 libtinfo.so.6
    "$D/bin/mysqld" --no-defaults --initialize-insecure --basedir="$D" --datadir="$T/data" > "$T/log" 2>&1 || {
      trace "$D/bin/mysqld" --no-defaults --initialize-insecure --basedir="$D" --datadir="$T/data-trace"
      fail "mysqld --initialize-insecure"
    }
    "$D/bin/mysqld" --no-defaults --basedir="$D" --datadir="$T/data" --port="$PORT" --bind-address=127.0.0.1 \
      --socket="$T/mysql.sock" --mysqlx=OFF --log-error="$T/log" &
    PID=$!
    wait_for '[ -S "$T/mysql.sock" ]' || fail "mysqld did not start"
    out="$("$D/bin/mysql" --no-defaults -uroot -h127.0.0.1 -P"$PORT" -N -e \
      "CREATE DATABASE smoke; CREATE TABLE smoke.t (id INT PRIMARY KEY, s VARCHAR(10)) ENGINE=InnoDB;
       INSERT INTO smoke.t VALUES (1, 'ok'); SELECT CONCAT(VERSION(), ' ', s) FROM smoke.t;")" || fail "query"
    "$D/bin/mysqldump" --no-defaults -uroot -h127.0.0.1 -P"$PORT" smoke > /dev/null 2>> "$T/log" || fail "mysqldump"
    "$D/bin/mysqladmin" --no-defaults -uroot -h127.0.0.1 -P"$PORT" shutdown || fail "mysqladmin shutdown"
    ;;
  postgresql)
    "$D/bin/initdb" -D "$T/data" -U postgres -A trust -E UTF8 --locale=C > "$T/log" 2>&1 || {
      trace "$D/bin/initdb" -D "$T/data-trace" -U postgres -A trust -E UTF8 --locale=C
      fail "initdb"
    }
    "$D/bin/postgres" -D "$T/data" -p "$PORT" -k "$T" -c listen_addresses=127.0.0.1 >> "$T/log" 2>&1 &
    PID=$!
    wait_for '"$D/bin/pg_isready" -q -h 127.0.0.1 -p "$PORT"' || fail "postgres did not start"
    out="$("$D/bin/psql" -X -q -A -t -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U postgres -c \
      "CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm; CREATE EXTENSION hstore; CREATE EXTENSION citext;
       CREATE TABLE t (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), s text);
       INSERT INTO t (s) VALUES ('ok');
       SELECT current_setting('server_version') || ' ' || current_setting('ssl_library') || ' ' || s || ' ' || length(digest('x', 'sha256')) FROM t;")" ||
      fail "query"
    "$D/bin/pg_dump" -h 127.0.0.1 -p "$PORT" -U postgres postgres > /dev/null || fail "pg_dump"
    "$D/bin/pg_ctl" -D "$T/data" stop -m fast > /dev/null || fail "pg_ctl stop"
    ;;
  mongodb)
    mkdir "$T/data"
    # On Linux, mongod runs with its bundled OpenSSL 3 (lib/), as Devid will run it.
    LIBS=""; [ -d "$D/lib" ] && LIBS="$D/lib"
    ldd_from "$D/lib" "$D/bin/mongod" libssl.so.3 libcrypto.so.3
    env ${LIBS:+LD_LIBRARY_PATH="$LIBS"} "$D/bin/mongod" --dbpath "$T/data" --port "$PORT" --bind_ip 127.0.0.1 --unixSocketPrefix "$T" --logpath "$T/log" &
    PID=$!
    wait_for 'grep -q "Waiting for connections" "$T/log" 2>/dev/null' || fail "mongod did not start"
    out="$(env ${LIBS:+LD_LIBRARY_PATH="$LIBS"} "$D/bin/mongod" --version | head -1)"
    # With a mongosh archive (MONGOSH=<archive>), a write and a read as well.
    if [ -n "${MONGOSH:-}" ]; then
      mkdir "$T/mongosh" && tar -xzf "$MONGOSH" -C "$T/mongosh"
      got="$("$T/mongosh/bin/mongosh" --quiet --nodb --norc --eval \
        "const c = connect('mongodb://127.0.0.1:$PORT/smoke'); c.t.insertOne({s: 'ok'}); print(c.t.findOne().s)")" ||
        fail "mongosh query"
      [ "$got" = ok ] || fail "mongosh read back '$got'"
      out="$out $got"
    fi
    # mongod shuts down cleanly on SIGTERM (its --shutdown option is Linux-only).
    kill -TERM "$PID"
    wait "$PID" || fail "mongod did not shut down cleanly"
    ;;
  mongosh)
    out="$("$D/bin/mongosh" --version)" || fail "mongosh --version"
    ;;
  *) fail "unknown engine $ENGINE" ;;
esac
wait "$PID" 2>/dev/null || true
PID=""
echo "smoke ok: $NAME: $out"
