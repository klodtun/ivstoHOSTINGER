#!/usr/bin/env bash
# Report what stands between an app and Hostinger. Changes nothing.
#
#   bash analyze-app.sh <app-dir>
#
# Exit 0 = nothing blocking found. Exit 1 = at least one blocker.
set -uo pipefail

APP="${1:-.}"
cd "$APP" || { echo "no such directory: $APP"; exit 2; }
APP_ABS="$PWD"

BLOCK=0
WARN=0
say()   { printf '%s\n' "$*"; }
block() { printf '  \033[31m✗\033[0m %s\n' "$*"; BLOCK=$((BLOCK+1)); }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }

say ""
say "Hostinger readiness — $APP_ABS"
say "================================================================"

# ── App type ────────────────────────────────────────────────────────────────
say ""
say "Runtime"
if [ -f package.json ]; then
  ENTRY=$(node -p "require('./package.json').main || 'server.js'" 2>/dev/null || echo server.js)
  ok "Node app (entry looks like: $ENTRY)"
  if [ -d backend ] && [ -f backend/main.py ]; then
    block "backend/main.py — this is a Python backend. Hostinger's app runtimes here are JavaScript only; it needs a VPS"
  fi
elif [ -f requirements.txt ] || [ -f main.py ] || [ -f app.py ]; then
  block "Python app (requirements.txt / main.py). Hostinger's app runtimes here are JavaScript only; it needs a VPS"
  ENTRY=""
elif [ -f index.html ]; then
  warn "Static site — deploy it as a static site; most of this skill does not apply"
  ENTRY=""
else
  block "cannot tell what this is: no package.json, no requirements.txt, no index.html"
  ENTRY=""
fi

[ -n "${ENTRY:-}" ] || { say ""; say "blockers: $BLOCK  warnings: $WARN"; [ "$BLOCK" -eq 0 ]; exit $?; }

# ── Trap 1: top-level await in the entry ────────────────────────────────────
say ""
say "Trap 1 — entry must be require()-able"
if [ -f "$ENTRY" ]; then
  TYPE=$(node -p "require('./package.json').type || 'commonjs'" 2>/dev/null || echo commonjs)
  if [ "$TYPE" = "module" ]; then
    if grep -nE '^(await |const [^=]*=[[:space:]]*await |let [^=]*=[[:space:]]*await )' "$ENTRY" >/dev/null 2>&1; then
      block "$ENTRY is an ES module with a top-level await → ERR_REQUIRE_ASYNC_MODULE (traps.md §1)"
      grep -nE '^(await |const [^=]*=[[:space:]]*await |let [^=]*=[[:space:]]*await )' "$ENTRY" | head -3 | sed 's/^/      /'
    else
      ok "ES module, no top-level await (verify-hostinger.sh is the authoritative check)"
    fi
  else
    ok "CommonJS entry — immune. Keep it that way"
  fi
else
  warn "entry file '$ENTRY' not found — check package.json main / the panel's Entry file"
fi

# ── Trap 3: install-only hosts ──────────────────────────────────────────────
say ""
say "Trap 3 — the host may run only 'npm install'"
if node -p "Object.keys(require('./package.json').scripts||{}).includes('postinstall')" 2>/dev/null | grep -q true; then
  ok "postinstall present"
else
  if node -p "Object.keys(require('./package.json').scripts||{}).includes('build')" 2>/dev/null | grep -q true; then
    block "there is a build script but no postinstall — a host that only runs 'npm install' will never build (traps.md §3)"
  else
    ok "no build step needed"
  fi
fi

# ── Trap 4: runtime deps in devDependencies ─────────────────────────────────
say ""
say "Trap 4 — NODE_ENV=production skips devDependencies"
for pkg in tsx prisma ts-node vite; do
  for dir in . api backend web frontend; do
    [ -f "$dir/package.json" ] || continue
    IN_DEV=$(node -p "!!(require('./$dir/package.json').devDependencies||{})['$pkg']" 2>/dev/null)
    [ "$IN_DEV" = "true" ] || continue
    case "$pkg" in
      tsx|prisma|ts-node)
        block "$dir/package.json has '$pkg' in devDependencies — it is needed at RUN time; move it to dependencies (traps.md §4)" ;;
      vite)
        if node -p "((require('./$dir/package.json').scripts||{}).postinstall||'')" 2>/dev/null | grep -q .; then
          block "$dir/package.json runs a postinstall but keeps 'vite' in devDependencies — production installs skip it (traps.md §4)"
        else
          warn "$dir/package.json has 'vite' in devDependencies — fine only if the build command uses --include=dev"
        fi ;;
    esac
  done
done
[ "$BLOCK" -gt 0 ] || ok "no run-time dependency is hiding in devDependencies"

# ── Traps 5 & 7: spawning at run time ───────────────────────────────────────
say ""
say "Traps 5 + 7 — no child processes at run time"
RUNTIME_JS=$(git ls-files '*.js' '*.ts' 2>/dev/null | grep -vE '(^|/)(test|tests|tools|scripts)/' | grep -v node_modules || true)
[ -n "$RUNTIME_JS" ] || RUNTIME_JS=$(ls ./*.js 2>/dev/null || true)
HITS=$(printf '%s\n' $RUNTIME_JS | xargs grep -nE "spawn\(|execSync\(|child_process" 2>/dev/null | grep -v "^$" || true)
if [ -n "$HITS" ]; then
  warn "spawns found in code that may run per request — each copy of the app multiplies these (traps.md §7)"
  printf '%s\n' "$HITS" | head -6 | sed 's/^/      /'
  printf '%s\n' "$HITS" | grep -E "'(npx|npm|node)'|\"(npx|npm|node)\"" >/dev/null 2>&1 && \
    block "spawning by command name — PATH has no node/npm/npx on this host; use process.execPath (traps.md §5)"
else
  ok "no spawn / execSync in run-time code"
fi

# ── Trap 6: native binaries ─────────────────────────────────────────────────
say ""
say "Trap 6 — native binaries lose their executable bit"
if grep -rqE '"(prisma|@prisma/client)"' package.json */package.json 2>/dev/null; then
  if grep -rq "chmodSync" ./*.js 2>/dev/null; then
    ok "Prisma present and something restores the executable bit"
  else
    block "Prisma present but nothing restores +x on its engines — deploys strip it (traps.md §6)"
  fi
else
  ok "no Prisma engines to worry about"
fi

# ── Boot behaviour ──────────────────────────────────────────────────────────
say ""
say "Boot behaviour"
if grep -rqE "listen\(" ./*.js 2>/dev/null; then
  if grep -rqE "(migrate deploy|createTable|CREATE TABLE)" ./*.js 2>/dev/null; then
    warn "schema work appears in the entry — make sure the port opens BEFORE it, or a slow first boot reads as a dead app"
  fi
  # Either spelled out in the listen() call, or held in a variable that
  # defaults to it — both are correct, and only checking the literal call
  # produced a false warning on an app that was doing the right thing.
  if grep -rqE "0\.0\.0\.0" ./*.js 2>/dev/null; then
    ok "binds 0.0.0.0"
  elif grep -rqE "listen\([^,)]*,\s*['\"]127\.0\.0\.1|localhost['\"]" ./*.js 2>/dev/null; then
    block "the listener binds loopback — unreachable from the platform, every request becomes 503"
  else
    warn "could not confirm the listener binds 0.0.0.0 (a loopback bind is unreachable from the platform)"
  fi
  grep -rq "process.env.PORT" ./*.js 2>/dev/null \
    && ok "reads PORT from the environment" \
    || block "does not read process.env.PORT — the platform assigns the port"
fi

# ── Database ────────────────────────────────────────────────────────────────
say ""
say "Database"
if [ -f api/prisma/schema.prisma ] || [ -f prisma/schema.prisma ]; then
  SCHEMA=$(ls api/prisma/schema.prisma prisma/schema.prisma 2>/dev/null | head -1)
  PROVIDER=$(grep -A3 "^datasource" "$SCHEMA" | grep provider | sed 's/.*"\(.*\)".*/\1/')
  if [ "$PROVIDER" = "sqlite" ]; then
    block "$SCHEMA still uses provider \"sqlite\" — switch to \"mysql\" (db-migration.md)"
  else
    ok "$SCHEMA provider: $PROVIDER"
    grep -q "@db.Text\|@db.VarChar" "$SCHEMA" \
      && ok "free-text columns declare their size" \
      || warn "no @db.Text / @db.VarChar in the schema — MySQL's default VARCHAR(191) REJECTS longer writes (db-migration.md)"
  fi
  [ -d "$(dirname "$SCHEMA")/migrations" ] \
    && ok "migrations are committed" \
    || block "no prisma/migrations/ — the database outlives the deploy now; generate a migration (db-migration.md)"
fi
grep -rq "better-sqlite3\|node:sqlite" ./*.js */*.js 2>/dev/null \
  && warn "SQLite driver referenced in code — make sure a MariaDB path exists and is selected by configuration"

# ── Packaging ───────────────────────────────────────────────────────────────
say ""
say "Packaging"
NONASCII=$(git ls-files 2>/dev/null | LC_ALL=C grep '[^ -~]' || true)
if [ -n "$NONASCII" ]; then
  warn "non-ASCII filenames — unzip mangles and truncates these; package-app.sh drops them:"
  printf '%s\n' "$NONASCII" | head -3 | sed 's/^/      /'
else
  ok "all filenames are ASCII"
fi

say ""
say "================================================================"
say "blockers: $BLOCK   warnings: $WARN"
if [ "$BLOCK" -gt 0 ]; then
  say "Fix the blockers, then run verify-hostinger.sh."
  exit 1
fi
say "Nothing blocking. Run verify-hostinger.sh to prove it under the host's conditions."
