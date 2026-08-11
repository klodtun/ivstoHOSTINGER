# ivs-to-hostinger

A Claude Code skill for moving an app from **iVS** (one Docker container,
embedded SQLite) to **Hostinger's Node hosting** (LiteSpeed, MariaDB over the
network).

iVS runs your app as a long-lived container it built for you. Hostinger runs it
under LiteSpeed, which `require()`s your entry file, starts a copy per request,
and caps how many processes your account may hold. Almost everything that breaks
follows from that one difference — and it all surfaces as the same bare `503`,
with a build log that looks perfect.

This skill exists because moving one real app cost seven rounds of *deploy → 503
→ read the runtime log → find something new*. Every one of those is now a check
that runs locally in under a minute.

## Install

```bash
git clone https://github.com/klodtun/ivstoHOSTINGER.git ~/.claude/skills/ivs-to-hostinger
```

Claude Code picks it up automatically. Invoke with `/ivs-to-hostinger`, or just
ask about deploying to Hostinger.

## Use

```bash
# What stands between this app and Hostinger — changes nothing
bash scripts/analyze-app.sh <app-dir>

# Prove it under the host's real conditions — the part that matters
bash scripts/verify-hostinger.sh <app-dir>

# Package + generate the environment file
bash scripts/package-app.sh <app-dir>
node scripts/gen-env.js <app-dir> > /tmp/APP-ENV.txt
```

`verify-hostinger.sh` reproduces, locally:

- the entry file `require()`-d from CommonJS
- `PATH` with no `node`, `npm` or `npx`
- only `npm install` — no build command
- `NODE_ENV=production`, so devDependencies are skipped
- native binaries with their executable bit stripped
- MariaDB 11.8.8 in Docker, empty database
- a count of child processes, which must be zero

It found two real bugs in an app that had already been "verified" by hand.

## The seven failure modes

| # | Symptom in the runtime log | Cause |
|---|---|---|
| 1 | `ERR_REQUIRE_ASYNC_MODULE` | Top-level `await` in the entry file |
| 2 | *No log at all, pages load, every `/api/*` 503* | Framework set to `Vite` / non-empty Output directory → published as a static site |
| 3 | Build log is one line: `up to date, audited 1 package` | The host only runs `npm install`; nothing built |
| 4 | `tsc: command not found`, module not found | `NODE_ENV=production` skipped devDependencies |
| 5 | `spawn npx ENOENT` | No Node tooling on the runtime PATH |
| 6 | `Schema engine exited … EACCES` | The deploy stripped `+x` from native binaries |
| 7 | `spawn … EAGAIN` | Process cap — a copy of the app per request, each spawning children |

Details, the fix for each, and how to reproduce them: [`references/traps.md`](references/traps.md).

## Contents

| Path | What it is |
|---|---|
| `SKILL.md` | Which app types can go at all, the workflow, the rules that follow |
| `references/traps.md` | The seven failure modes in full |
| `references/db-migration.md` | SQLite → MariaDB: column types, migrations, seeding, moving existing rows |
| `references/panel-settings.md` | Panel fields, log-line → cause triage, SSH commands |
| `scripts/analyze-app.sh` | Static check; reports blockers and warnings |
| `scripts/verify-hostinger.sh` | The harness |
| `scripts/package-app.sh` | Deployment zip from committed files only |
| `scripts/gen-env.js` | Environment file from the variables the source actually reads |

## Requirements

Node 18+, Docker (for the harness), `git`, `zip`. Tested on macOS.

## Scope

Hostinger's app runtimes here are JavaScript only. **Python apps — FastAPI,
Streamlit, or an iVS `fullstack` app with a Python backend — cannot go**; they
need a VPS. The skill says so before you start rather than after.

The harness checks the deployment shape, not your application logic. Keep your
own tests.

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, ship it.

The skill describes how to deploy on a third-party platform; it is not
affiliated with, endorsed by, or supported by Hostinger.
