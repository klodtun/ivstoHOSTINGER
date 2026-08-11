---
name: ivs-to-hostinger
description: "Move an app that runs on iVS (single Docker container, embedded SQLite) to Hostinger's Node hosting (LiteSpeed, MariaDB over the network). Use when asked to deploy an iVS app to Hostinger, to check whether an app can go, when a Hostinger deploy answers 503, or when planning the SQLite → MariaDB switch. Covers the compatibility check, the seven failure modes that produce a bare 503, the packaging rules, and a verification harness that reproduces the host's runtime locally before anything is uploaded."
---

# iVS → Hostinger

iVS runs an app as a long-lived Docker container it built for you. Hostinger runs
it under LiteSpeed, which `require()`s your entry file, starts a copy per request,
and caps how many processes your account may hold. Almost everything that breaks
follows from that one difference.

This skill exists because moving one app cost seven rounds of "deploy → bare 503 →
read the runtime log → find something new". Every one of those is now a check that
runs locally in under a minute.

## Decide first: can this app go at all?

| iVS app type | Hostinger | What to do |
|---|---|---|
| `nodejs`, `nodejs_vite` | ✅ | This skill |
| `static`, `static_prebuilt` | ✅ | Static site — no Node needed, skip most of this |
| `nodejs_nextjs` | ✅ | Supported runtime, but check the entry: Next's own server must be the entry file |
| `python`, `python_fastapi`, `python_streamlit` | ❌ | Hostinger's app runtimes here are JavaScript only. Needs a VPS |
| `fullstack` (FastAPI + React) | ❌ | The backend is Python. Either keep it on iVS, take a VPS, or rewrite the backend in a supported framework |

Say this out loud before touching anything. Telling someone on day one that their
Streamlit app cannot go is worth more than a week of finding out.

## Workflow

```bash
# 1. Report what stands between this app and Hostinger — changes nothing
bash ~/.claude/skills/ivs-to-hostinger/scripts/analyze-app.sh <app-dir>

# 2. Make the changes it lists (see references/traps.md for each one)

# 3. Prove it locally under the host's real conditions — this is the whole point
bash ~/.claude/skills/ivs-to-hostinger/scripts/verify-hostinger.sh <app-dir>

# 4. Package + generate the environment file
bash ~/.claude/skills/ivs-to-hostinger/scripts/package-app.sh <app-dir> [git-ref]
node ~/.claude/skills/ivs-to-hostinger/scripts/gen-env.js <app-dir> > /tmp/APP-ENV.txt
```

Never skip step 3. A deploy that has not been through the harness will find the
next trap in production, where the only feedback is `503` and a log page the user
has to know exists.

## The seven failure modes

All seven produce the same symptom — a bare 503 — and the build log looks perfect
for six of them. Full detail, with the log line that identifies each, in
[references/traps.md](references/traps.md).

1. **Top-level `await` in the entry file** → `ERR_REQUIRE_ASYNC_MODULE`. LiteSpeed
   `require()`s the entry; an ESM graph with a top-level await throws before any
   code runs. Wrap startup in an async IIFE.
2. **Framework set to `Vite`, or a non-empty Output directory** → the platform
   publishes your build folder as a static site and never runs Node. Pages load,
   every `/api/*` is 503, and the runtime log is empty because there is no process.
3. **The host only runs `npm install`** → no build command, no `dist/`, no
   workspace installs. Add a `postinstall` that builds.
4. **`NODE_ENV=production` skips devDependencies** → anything needed at run time
   (`tsx`, `prisma`, a bundler used by `postinstall`) must be in `dependencies`.
5. **No `node`, `npm` or `npx` on the runtime PATH** → `spawn npx ENOENT`. Use
   `process.execPath` and a direct path to the CLI's own entry file.
6. **File modes are not preserved by the deploy** → native binaries (Prisma's
   engines) lose `+x` and fail with a bare `EACCES`. Restore the bit at boot.
7. **Process cap** → `spawn … EAGAIN`. A copy of the app starts per request; if
   each copy spawns children, the account's limit fills and nothing ever starts.
   **No child processes at run time. None.**

## The rules that follow

- **One process.** Mount the API in the same process as the static server. No
  child process, no internal port, no reverse proxy to loopback.
- **Nothing heavy at boot.** Migrations and seeding are deploy steps (they may
  spawn — the build phase has room). Boot should only listen.
- **Open the port first.** Do slow work after, and answer `/api/*` with
  `503 {"error":"STARTING"}` until ready. A host that health-checks during a long
  boot reports the whole app as down.
- **Bind `0.0.0.0`, read `PORT`.** Log the resolved URL and whether `PORT` was
  injected — that one line separates three different failures.
- **Fail loudly at boot** when configuration is missing, naming the variable.
  A missing key must never look like a mysterious 503.

## Database: SQLite → MariaDB

The part with the most hidden edges. See
[references/db-migration.md](references/db-migration.md) for the column-type
rules (MySQL's `VARCHAR(191)` **rejects** longer writes rather than truncating),
migrations vs `db push`, seeding only an empty database, and moving existing rows.

Prefer separate `DB_HOST` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` variables over a
single `DATABASE_URL` where the app supports it: a URL turns every `@ # / % &` in
the password into a parsing bug, and the error it produces (`P1000` authentication
failed) points at the wrong thing.

## Panel settings

The two fields that silently turn a Node app into a static site, the build and
start commands, and a table that maps a runtime-log line to its cause:
[references/panel-settings.md](references/panel-settings.md).

## What iVS gives you that Hostinger does not

Say this to whoever signs off, before the move:

- **Audit chain, retention, PDPA controls** live in iVS. Once the app is on
  Hostinger they are the app's own problem. If the app carries an audit chain,
  its anchor must now be published somewhere outside that host.
- **App export/restore** — iVS bundles source and data together. On Hostinger the
  data lives in MariaDB, which is better for surviving a redeploy, but backups are
  now the hosting account's job.
- **Vault** — secrets move to the panel's environment variables, in plain text, to
  whoever can open that page.

Data survives a redeploy on Hostinger. It does not on iVS. That is often the whole
reason for the move — say so plainly rather than treating it as a footnote.
