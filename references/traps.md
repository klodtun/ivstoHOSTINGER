# The seven failure modes

Every one of these was hit deploying one real app. Each produced the same symptom
— a bare `503 Service Unavailable` from LiteSpeed — and for six of the seven the
**build log looked perfect**. The build log and the runtime log are different
pages in the panel: **การปรับใช้ → (a deployment) → สร้างบันทึก** is the build,
**บันทึกเวลาการทำงาน** is the running app. A crash at startup only appears in the
second one.

---

## 1. Top-level `await` in the entry file

**Runtime log**

```
Error [ERR_REQUIRE_ASYNC_MODULE]: require() cannot be used on an ESM graph with
top-level await. Use import() instead.
From /usr/local/lsws/fcgi-bin/lsnode.js
Requiring …/nodejs/server.js
```

LiteSpeed's `lsnode.js` starts the app by `require()`-ing the entry file. Node can
`require()` an ES module — but not one whose graph contains a top-level `await`.
It throws before a single line of the app runs.

**Fix** — keep the async startup inside a function:

```js
void (async () => {
  try {
    await ensureApi();
    listening = true;
  } catch (err) {
    console.error('[server] startup failed:', err.message);
    process.exit(1);
  }
})();
```

CommonJS entries are immune. If the entry is CJS, keep it that way, and say so in
a comment so nobody "modernises" it later.

**Reproduce locally** — `scripts/verify-hostinger.sh` does this with a CJS loader
that `require()`s the entry. Fails identically to production before the fix.

---

## 2. Framework `Vite`, or a non-empty Output directory

**Symptom** — the pages load, every `/api/*` returns 503, and the runtime log is
completely empty (`ข้อผิดพลาด: 0`, "ไม่พบบันทึก"). On the server,
`hbuilds/current/` contains only `public_html/` — no `nodejs/` directory.

The platform read "this is a Vite project / here is my output folder" as "publish
these files as a static site". It never ran Node at all, which is why there is no
log: there is no process.

**Fix** — in the deploy settings:

```
Framework:         Other        ← not Vite, not React, not anything else
Root directory:    ./
Output directory:  (empty)      ← this field is the trap
Entry file:        server.js
```

The app serves its own built frontend. The platform must not be told about it.

---

## 3. The host only runs `npm install`

**Build log**

```
up to date, audited 1 package in 486ms
found 0 vulnerabilities
```

One line, nothing else. A monorepo root with no dependencies of its own installs
nothing, builds nothing, and the app has no chance.

**Fix** — a `postinstall` that builds, so a bare `npm install` prepares everything:

```json
{
  "scripts": {
    "build": "npm --prefix web install --include=dev && npm --prefix web run build && npm --prefix api install && npm --prefix api run build",
    "postinstall": "npm run build"
  }
}
```

If the build is optional (the server can serve unbundled files), make it
non-fatal so a failure cannot abort the install:

```json
"postinstall": "npm run build || echo '[postinstall] build skipped — serving unbundled files'"
```

---

## 4. `NODE_ENV=production` skips devDependencies

Silent until something is missing at run time. `tsx`, `prisma`, and anything a
`postinstall` invokes are **run-time** dependencies on this host even if the
ecosystem calls them dev tools.

**Fix**

- Move anything needed to *run* into `dependencies` (`prisma`, `tsx`).
- Anything needed only to *build* can stay in `devDependencies` **if** the build
  command installs with `--include=dev`:

```
npm --prefix web install --include=dev --no-audit --no-fund
```

For a single-package repo where `postinstall` runs the bundler, the bundler has to
be a real dependency — there is no second install to add `--include=dev` to.

---

## 5. No `node`, `npm` or `npx` on the runtime PATH

**Runtime log**

```
[server] startup failed: spawn npx ENOENT
```

The app was running (the line above it says it is listening). PATH under LiteSpeed
has none of the Node tooling.

**Fix** — never spawn by command name. Use the binary already executing this
process, and address the CLI by its own entry file:

```js
const PRISMA_CLI = join(API_DIR, 'node_modules', 'prisma', 'build', 'index.js');
await run(process.execPath, [PRISMA_CLI, 'migrate', 'deploy']);
```

Also wrap any `execSync('npm …')` fallback in a try/catch that warns instead of
killing the process.

---

## 6. File modes are not preserved

**Runtime log**

```
Error: Schema engine exited. Command failed with EACCES:
  …/api/node_modules/@prisma/engines/schema-engine-debian-openssl-1.1.x
  spawn … EACCES
```

The deploy pipeline copies the built tree into `versions/<id>/` without preserving
modes. Native binaries arrive without `+x`.

**Fix** — put the bit back before using them:

```js
for (const dir of [join(API_DIR, 'node_modules', '@prisma', 'engines'),
                   join(API_DIR, 'node_modules', '.prisma', 'client')]) {
  if (!existsSync(dir)) continue;
  for (const name of readdirSync(dir)) {
    if (!/engine|\.node$/.test(name)) continue;
    const file = join(dir, name);
    if (statSync(file).mode & 0o111) continue;
    chmodSync(file, 0o755);
    console.log(`[server] restored the executable bit on ${name}`);
  }
}
```

**Reproduce locally** — `chmod 644` the engines, then boot. Exactly the production
error.

---

## 7. Process cap — `spawn … EAGAIN`

**Runtime log**

```
[server] Guest Event listening on http://0.0.0.0:3000/ (PORT=3000)
[server] startup failed: spawn /opt/alt/alt-nodejs22/root/usr/bin/node EAGAIN
```

repeated every few seconds, once per incoming request.

`EAGAIN` on spawn means the account cannot create another process. LiteSpeed
starts a copy of the app per request; if each copy spawns children — a migration
CLI, a TypeScript loader, an API child — the cap fills and every copy after that
dies at the same line.

**Fix** — no child processes at run time, at all:

- **Mount the API in-process.** Build the framework instance without listening,
  and hand requests to it directly:

  ```js
  // api/src/app.ts — no listen, no top-level await
  export async function buildApp() { /* register everything */ return app; }
  ```

  ```js
  // server.js
  const { buildApp } = await import(pathToFileURL(join(API_DIR, 'dist', 'app.js')).href);
  const api = await buildApp({ logger: false });
  await api.ready();
  // …then, per request:
  req.url = req.url.replace(/^\/api/, '') || '/';
  api.routing(req, res);   // Fastify. Express: app(req, res)
  ```

- **Compile TypeScript at build time.** `tsx` at run time is another process and
  another dependency; `tsc -p tsconfig.build.json` at build removes both.
- **Move migrations and seeding to the build step.** They may spawn there.

Verify it: the harness counts child processes and fails if there are any.

---

## Two more worth knowing

**Credentials in a URL.** `DATABASE_URL=mysql://user:p@ss@host/db` parses wrong and
reports `P1000: Authentication failed`, which sends you hunting the password
instead of the encoding. Either URL-encode (`@`→`%40`, `#`→`%23`, `/`→`%2F`,
`%`→`%25`, `&`→`%26`, `?`→`%3F`, `:`→`%3A`), use an alphanumeric password, or
prefer separate `DB_*` variables.

Prove the credentials independently before blaming the app:

```bash
mysql -u USER -pPASS -h 127.0.0.1 -P 3306 DBNAME -e "SELECT 1"
```

If that works and the app still says `P1000`, the value in the panel is not what
you think it is — delete the variable and create it again, with no quotes and no
trailing whitespace.

**Non-ASCII filenames in the zip.** `unzip` mangles UTF-8 names that were stored
without the UTF-8 flag, and truncates the file. Keep them out of the deployment
package — `scripts/package-app.sh` does this and tells you what it dropped.
