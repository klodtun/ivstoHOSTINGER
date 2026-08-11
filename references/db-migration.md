# SQLite (iVS) → MariaDB (Hostinger)

On iVS the database is a file inside the container: it dies with every rebuild,
and `prisma db push` against it is harmless. On Hostinger it is a server that
outlives every deploy, which changes three things — column types, how the schema
is applied, and when it is safe to seed.

Verified against **MariaDB 11.8.8** with Prisma 5.22's `mysql` connector.

---

## Connect

MariaDB speaks the MySQL protocol. The URL scheme is `mysql://`:

```
DATABASE_URL=mysql://USER:PASSWORD@localhost:3306/DATABASE
```

Both the database name and the user carry the hosting account's prefix
(`uXXXXXXXX_guestevent`) — use the full names.

**Prefer separate variables when the app supports them.** A password with any of
`@ # / % & ? :` turns a URL into a parsing bug whose error message
(`P1000 Authentication failed`) points at the password rather than at the URL:

```
DB_HOST=localhost
DB_PORT=3306
DB_USER=uXXXXXXXX_app
DB_PASSWORD=…
DB_NAME=uXXXXXXXX_app
```

`localhost` and `127.0.0.1` are not the same thing to MySQL — the first is a unix
socket, the second is TCP, and the grants can differ. Test both before concluding
anything:

```bash
mysql -u USER -pPASS -h localhost      DBNAME -e "SELECT 1"   # socket
mysql -u USER -pPASS -h 127.0.0.1 -P 3306 DBNAME -e "SELECT 1"   # TCP
mysql -u USER -pPASS -e "SELECT @@socket"                      # socket path if needed
```

Prisma can be pointed at the socket: `mysql://user:pass@localhost/db?socket=/var/lib/mysql/mysql.sock`.

---

## Column types — the one that bites

MySQL's default for a Prisma `String` is `VARCHAR(191)`. It does not truncate a
longer value; **it rejects the write**. Everything that holds free text has to say
how long it can be:

```prisma
summary   String  @db.Text                 // audit summaries, notes
detail    String? @db.Text                 // JSON blobs
quotaInfo String? @default("{}") @db.VarChar(2000)
reason    String? @db.VarChar(500)
```

Rules:

- **Indexed or unique columns stay `VarChar`.** MySQL cannot index `TEXT` without a
  prefix length.
- **A column with a default cannot be `TEXT`** in the general case — give it
  `@db.VarChar(n)` so the default survives.
- Hashes and tokens are fixed-length and fine as-is (a 64-char hex fits 191).

Audit the schema for anything free-text: `summary`, `detail`, `note`, `reason`,
`description`, `userAgent`, and any column holding serialised JSON.

## Keep the schema portable

If the app still has to run on iVS/SQLite from another branch, the schema file is
shared. **No `enum`, no `Json`** — neither exists in SQLite through Prisma. Keep
using `String` plus `JSON.stringify`, and put the reason in a comment so the next
person does not "fix" it.

---

## Migrations, not `db push`

The database now outlives the deployment, so a schema change has to be reviewable
and replayable:

```bash
DATABASE_URL="mysql://…" npx prisma migrate dev --name init   # once, to generate
DATABASE_URL="mysql://…" npx prisma migrate deploy            # every deploy
```

Commit `prisma/migrations/`. `db push --accept-data-loss` against a live database
is how you lose a customer's rows.

**Run migrations in the build step, never at boot** — see trap 7. The build phase
has time and can spawn processes; a request-triggered boot has neither:

```json
"build": "… && npm run db:deploy"
```

Make it non-fatal: a deploy that cannot reach the database should still publish, and
the app should then say so itself.

---

## Seeding

"Is this a fresh install?" used to be "does the SQLite file exist". With a managed
database, ask the database — **no user accounts means nobody could sign in**, which
is the only state where seeding over the top is safe:

```ts
const users = await prisma.user.count();
console.log(users === 0 ? 'EMPTY' : `HAS_DATA(${users} users)`);
```

Seed only on `EMPTY`. Anything else and a redeploy silently overwrites live data —
which is exactly the iVS behaviour people are trying to leave behind.

---

## Moving existing rows from an iVS instance

Not automated, and worth doing deliberately.

1. Export the app from iVS (`POST /api/apps/{id}/export`) — the bundle contains the
   SQLite file.
2. Apply the migrations to the MariaDB database first, so the target schema exists.
3. Copy in dependency order: events → config → guests → credentials → check-ins →
   audit. A script with two Prisma clients (one `sqlite`, one `mysql`) is the
   simplest correct approach.
4. **Copy `id` and every timestamp verbatim.** Regenerated ids break foreign keys;
   regenerated timestamps break anything signed.
5. **An audit chain only survives if every signed field is byte-identical and the
   signing key comes across too.** Verify after loading — if the app has a
   `verify-chain` endpoint, it must still report `ok: true`. If it does not, say so
   rather than shipping a chain that silently proves nothing.
6. Compare row counts per table before declaring it done.

---

## Local MariaDB for development

```bash
docker run -d --name app-mariadb \
  -e MARIADB_ROOT_PASSWORD=devroot -e MARIADB_DATABASE=appdb \
  -p 3306:3306 mariadb:11.8.8

export DATABASE_URL="mysql://root:devroot@127.0.0.1:3306/appdb"
```

Use the same major version as the host. `scripts/verify-hostinger.sh` starts one
on a spare port automatically.
