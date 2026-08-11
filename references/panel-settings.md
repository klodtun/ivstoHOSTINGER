# Hostinger panel — settings and triage

## Deployment settings

```
Framework:         Other        ← not Vite / React / anything else
Root directory:    ./           ← the folder holding the entry file
Output directory:  (empty)      ← must be empty for a Node app
Entry file:        server.js
Package manager:   npm
Build command:     npm install
Start command:     npm start
Node version:      22.x
```

**The two fields that silently break a Node app**

| Set to | What happens |
|---|---|
| Framework = `Vite` | The platform publishes the build folder as a static site and never runs Node. Pages load, every `/api/*` is 503, the runtime log is empty, and `hbuilds/current/` holds only `public_html/` |
| Output directory = `dist` / `web/dist` | Identical outcome |

The app serves its own built frontend. Telling the platform where that folder is
converts the deployment into a static site.

**Advice that does not apply to this shape of app** — and support/AI assistants
give it often:

| Suggestion | Why it is wrong here |
|---|---|
| Start command `npm run build` | Builds, exits, nothing listens → 503 |
| Start command `vite preview --host 0.0.0.0 --port 3000` | Serves the pages with **no backend** — the UI loads and nothing works |
| Root directory `dist/` | It is a Node app; the server needs its whole tree |

## Environment variables

Set every one **before** the first deploy — a well-built app refuses to start
without its keys and says which are missing, and that message only reaches the
runtime log.

- No surrounding quotes. No trailing whitespace or newline.
- If a value looks wrong, **delete the variable and create it again** rather than
  editing in place.
- `PORT` is usually injected. If the app's log says `PORT=unset, defaulted to
  8080` while the platform expects 3000, set it explicitly.

## Where the logs are

Two different pages, and the difference matters:

| Page | Shows |
|---|---|
| การปรับใช้ → (a deployment) → **สร้างบันทึก** | The **build**: install and build output |
| **บันทึกเวลาการทำงาน** | The **running app**: everything it prints, and every crash |

A startup crash appears only in the second. Six of the seven failure modes leave
the build log looking perfect.

## Triage: runtime log line → cause

| Log | Cause | Fix |
|---|---|---|
| `ERR_REQUIRE_ASYNC_MODULE … Requiring …/server.js` | Top-level `await` in the entry | Trap 1 |
| *(nothing at all, errors 0, pages still load)* | Deployed as a static site | Trap 2 — Framework/Output directory |
| Build log is one line: `up to date, audited 1 package` | Only `npm install` ran | Trap 3 — add `postinstall` |
| `Cannot find module 'tsx'` / a bundler missing | `NODE_ENV=production` skipped devDependencies | Trap 4 |
| `startup failed: spawn npx ENOENT` | No `npx`/`node` on PATH | Trap 5 — `process.execPath` |
| `Schema engine exited … EACCES` | Native binary lost `+x` | Trap 6 — chmod at boot |
| `startup failed: spawn … EAGAIN` | Account process cap | Trap 7 — no child processes |
| `P1000: Authentication failed` | Password wrong, or special characters in a URL | references/db-migration.md |
| `listening on …:8080` but the host expects another port | `PORT` not injected | Set `PORT` |
| `{"error":"STARTING"}` on `/api/*` | The app is up and preparing | Wait; if it never clears, read the next error |

## Checks after deploying

```bash
curl -i https://APP-DOMAIN/api/health     # or whatever the app's liveness route is
curl -s -o /dev/null -w '%{http_code}\n' https://APP-DOMAIN/
```

- `{"ok":true,…}` — done.
- `{"error":"STARTING"}` — still preparing; wait and repeat.
- LiteSpeed's HTML 503 — nothing is answering. Go to the runtime log.

## SSH

Hostinger exposes SSH (**ขั้นสูง → การเข้าถึง SSH**), which is the fastest way to
settle a question the panel cannot answer:

```bash
ssh -p 65002 uXXXXXXXX@HOST-IP

# where the running copy actually is
find ~/domains/DOMAIN/hbuilds -maxdepth 4 -name server.js -not -path "*/node_modules/*"

# do the credentials work at all?
mysql -u USER -pPASS -h 127.0.0.1 -P 3306 DBNAME -e "SELECT 1"

# run the migrations by hand, bypassing the panel's environment
cd ~/domains/DOMAIN/hbuilds/current/nodejs
DATABASE_URL="mysql://…" node api/node_modules/prisma/build/index.js migrate deploy
```

`hbuilds/current` is a symlink to `versions/<id>/`; the app lives under `nodejs/`
inside it. If `nodejs/` is missing, the deployment was published as a static site
(trap 2).

Never paste a password into a chat or an issue. If one leaks, rotate it once the
deploy is working.
