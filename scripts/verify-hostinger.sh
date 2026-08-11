#!/usr/bin/env bash
# Reproduce Hostinger's runtime locally and prove the app survives it.
#
#   bash verify-hostinger.sh <app-dir> [--port 3099] [--no-db] [--env-file FILE]
#
# What it recreates, and why each one matters:
#   * the entry file is require()-d from CommonJS   → trap 1 (ERR_REQUIRE_ASYNC_MODULE)
#   * PATH holds no node, npm or npx                → trap 5 (spawn ENOENT)
#   * only `npm install` runs — no build command    → trap 3 (nothing gets built)
#   * NODE_ENV=production                           → trap 4 (devDependencies skipped)
#   * native binaries are chmod 644 first           → trap 6 (EACCES)
#   * child processes are counted, and must be 0    → trap 7 (EAGAIN under the process cap)
#   * MariaDB 11.8.8 in Docker, empty database      → the real database
#
# Exit 0 = ready to package.
set -uo pipefail

APP=""; PORT=3099; DBPORT=33099; USE_DB=1; ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --db-port) DBPORT="$2"; shift 2 ;;
    --no-db) USE_DB=0; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done
[ -n "$APP" ] || APP="."
cd "$APP" || { echo "no such directory: $APP"; exit 2; }
APP_ABS="$PWD"
NODE_BIN="$(command -v node)"
[ -n "$NODE_BIN" ] || { echo "node not found on PATH"; exit 2; }

WORK="$(mktemp -d)"
CONTAINER="verify-hostinger-$$"
FAIL=0
cleanup() {
  if [ -n "${APP_PID:-}" ]; then kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi
  pkill -f "$WORK/lsnode-sim.cjs" 2>/dev/null
  [ "$USE_DB" = "1" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

step "1/6  Staging a clean copy (only what a deploy would carry)"
if git -C "$APP_ABS" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$APP_ABS" archive --format=tar HEAD | (cd "$WORK" && tar x)
  ok "staged from git HEAD — untracked files excluded, as in the real package"
else
  tar --exclude=node_modules --exclude=.git --exclude=dist -cf - -C "$APP_ABS" . | (cd "$WORK" && tar x)
  ok "staged by copy (not a git repo — untracked files are included, unlike a real package)"
fi
cd "$WORK"

if [ "$USE_DB" = "1" ]; then
  step "2/6  MariaDB 11.8.8, empty database"
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  if ! docker run -d --name "$CONTAINER" \
      -e MARIADB_ROOT_PASSWORD=verifypw -e MARIADB_DATABASE=verifydb \
      -p "$DBPORT":3306 mariadb:11.8.8 >/dev/null 2>&1; then
    bad "could not start MariaDB (is Docker running?) — rerun with --no-db to skip"
    USE_DB=0
  else
    for _ in $(seq 1 40); do
      docker exec "$CONTAINER" mariadb -uroot -pverifypw -e "SELECT 1" >/dev/null 2>&1 && break
      sleep 2
    done
    docker exec "$CONTAINER" mariadb -uroot -pverifypw -e "SELECT VERSION()" >/dev/null 2>&1 \
      && ok "MariaDB up on 127.0.0.1:$DBPORT" || bad "MariaDB never became ready"
  fi
else
  step "2/6  MariaDB — skipped (--no-db)"
fi

step "3/6  npm install only, NODE_ENV=production"
# The real build phase has the environment variables too — that is where a
# well-built app applies its migrations, so give the install the same values.
INSTALL_ENV=(NODE_ENV=production)
[ "$USE_DB" = "1" ] && INSTALL_ENV+=(
  DATABASE_URL="mysql://root:verifypw@127.0.0.1:$DBPORT/verifydb"
  DB_HOST=127.0.0.1 DB_PORT="$DBPORT" DB_USER=root DB_PASSWORD=verifypw DB_NAME=verifydb
)
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    INSTALL_ENV+=("$line")
  done < "$ENV_FILE"
fi
if env "${INSTALL_ENV[@]}" npm install --no-audit --no-fund > "$WORK/.install.log" 2>&1; then
  ok "install succeeded"
  grep -qE "postinstall" "$WORK/.install.log" && ok "postinstall ran" \
    || printf '  \033[33m!\033[0m no postinstall — fine only if this app needs no build\n'
  grep -qE "migrat" "$WORK/.install.log" && ok "migrations ran in the build step (where they belong)"
else
  bad "npm install failed:"; tail -15 "$WORK/.install.log" | sed 's/^/      /'
fi

step "4/6  Stripping the executable bit from native binaries (trap 6)"
STRIPPED=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  chmod 644 "$f" 2>/dev/null && STRIPPED=$((STRIPPED+1))
done < <(find . -path '*/node_modules/@prisma/engines/*' -type f \( -name '*engine*' -o -name '*.node' \) 2>/dev/null)
[ "$STRIPPED" -gt 0 ] && ok "stripped $STRIPPED binaries — the app must restore them" || ok "no native engine binaries present"

step "5/6  Booting: require()-d from CommonJS, PATH without node/npm/npx"
cat > "$WORK/lsnode-sim.cjs" <<'EOF'
// Stands in for LiteSpeed's lsnode.js: a CommonJS loader that require()s the entry.
const target = process.argv[2];
console.log('[verify] require(' + target + ')');
require(target);
EOF
ENTRY=$(node -p "require('$WORK/package.json').main || 'server.js'" 2>/dev/null || echo server.js)
[ -f "$WORK/$ENTRY" ] || ENTRY="server.js"

ENVARGS=(PATH=/usr/bin:/bin NODE_ENV=production PORT="$PORT")
[ "$USE_DB" = "1" ] && ENVARGS+=(
  DATABASE_URL="mysql://root:verifypw@127.0.0.1:$DBPORT/verifydb"
  DB_HOST=127.0.0.1 DB_PORT="$DBPORT" DB_USER=root DB_PASSWORD=verifypw DB_NAME=verifydb
)
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    ENVARGS+=("$line")
  done < "$ENV_FILE"
  ok "extra environment from $ENV_FILE"
fi

env "${ENVARGS[@]}" "$NODE_BIN" "$WORK/lsnode-sim.cjs" "$WORK/$ENTRY" > "$WORK/.boot.log" 2>&1 &
APP_PID=$!

READY=0
for i in $(seq 1 45); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)
  [ "$code" = "200" ] && { READY=$i; break; }
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 2
done

if grep -q "ERR_REQUIRE_ASYNC_MODULE" "$WORK/.boot.log"; then
  bad "ERR_REQUIRE_ASYNC_MODULE — the entry has a top-level await (traps.md §1)"
fi
grep -q "ENOENT" "$WORK/.boot.log" && bad "spawn ENOENT — something is spawned by command name (traps.md §5)"
grep -q "EACCES" "$WORK/.boot.log" && bad "EACCES — a native binary is not executable and nothing restored it (traps.md §6)"
grep -q "EAGAIN" "$WORK/.boot.log" && bad "EAGAIN — hit a process limit (traps.md §7)"

if [ "$READY" -gt 0 ]; then
  ok "GET / answered 200 after ~$((READY*2))s"
  [ "$READY" -le 3 ] || printf '  \033[33m!\033[0m took a while — make sure the port opens before the slow work\n'
else
  bad "GET / never answered 200. Boot log:"; tail -20 "$WORK/.boot.log" | sed 's/^/      /'
fi

step "6/6  Counting child processes (must be zero — trap 7)"
SIM_PID=$(pgrep -f "$WORK/lsnode-sim.cjs" | head -1)
if [ -n "$SIM_PID" ]; then
  KIDS=$(pgrep -P "$SIM_PID" 2>/dev/null | wc -l | tr -d ' ')
  [ "$KIDS" = "0" ] && ok "0 child processes" \
    || bad "$KIDS child process(es) — every copy of the app multiplies these until the account's cap is hit (traps.md §7)"
else
  bad "the app process is not running"
fi

for path in /api/health /health /api/v1/health; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$path" 2>/dev/null)
  case "$code" in
    200) ok "$path → 200" ; break ;;
    503) printf '  \033[33m!\033[0m %s → 503 (still starting — acceptable, it says so honestly)\n' "$path"; break ;;
  esac
done

printf '\n\033[1m================================================================\033[0m\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mPASS\033[0m — survives the host conditions. Package it.\n'
else
  printf '\033[31mFAIL\033[0m — %s problem(s). Full boot log: %s\n' "$FAIL" "$WORK/.boot.log"
  cp "$WORK/.boot.log" "$APP_ABS/.verify-hostinger.log" 2>/dev/null && \
    printf 'Copied to %s/.verify-hostinger.log\n' "$APP_ABS"
fi
exit "$FAIL"
