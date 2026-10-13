# sqlserver-bootstrap

A Docker Compose stack that starts **SQL Server** and automatically restores a `.bak`
backup into it on first boot. Point it at a backup file, run `docker compose up`, and you
get a running database with your data already loaded — no manual `RESTORE` statements, no
figuring out `MOVE` clauses for the data files.

The restore is **idempotent**: it runs once, then skips on every subsequent `up`.

## Why

Restoring a `.bak` into a containerized SQL Server by hand is more annoying than it should
be. You have to read the logical file names out of the backup with `RESTORE FILELISTONLY`,
then hand-write a `MOVE` clause for every `.mdf`/`.ndf`/`.ldf` so the files land somewhere
that exists inside the container. This stack does that for you, whatever the backup
contains.

### Why restore on `up`

A `.bak` is a single static artifact: you drop it in once, and it's consumed once per
volume. Restoring on `up` and skipping afterwards fits that. postgres-bootstrap does the
opposite — it refreshes repeatedly from live sources — so there an on-demand
`docker compose run` fits better.

## Requirements

- Docker + Docker Compose
- A SQL Server `.bak` file, from the **same or an older** SQL Server version than the image.
  SQL Server can't restore a backup taken on a newer version.
- An amd64 host. The SQL Server image is amd64 only; on Apple Silicon it runs emulated
  (enable Rosetta in Docker Desktop), which works but is slower.

> Backups are **not** included in this repo, and `.bak` files are git-ignored on purpose:
> they are typically hundreds of MB (GitHub rejects any file over 100 MB) and usually hold
> real data. Keep yours out of version control.

## Quick start

```bash
# 1. Configure
cp .env.example .env
#    edit .env and set MSSQL_SA_PASSWORD (and MSSQL_DATABASE, the name to restore as)

# 2. Drop your backup in
cp /path/to/your-backup.bak baks/

# 3. Start
docker compose up -d

# 4. Watch the restore
docker compose logs -f restore-mssql   # wait for "✅ Restore complete"
```

Then connect from the host. `sqlcmd` reads the password from `SQLCMDPASSWORD`, so it never
goes on the command line:

```bash
# bash
export SQLCMDPASSWORD='<MSSQL_SA_PASSWORD>'
sqlcmd -C -S localhost,1433 -U sa -Q "SELECT name FROM sys.databases"
```

```powershell
# PowerShell
$env:SQLCMDPASSWORD = '<MSSQL_SA_PASSWORD>'
sqlcmd -C -S localhost,1433 -U sa -Q "SELECT name FROM sys.databases"
```

Inside the container `SQLCMDPASSWORD` is already set, so `docker compose exec` needs nothing:

```bash
docker compose exec mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -Q "SELECT @@VERSION"
```

## Configuration

All settings live in `.env`. Server settings use the image's own `MSSQL_` prefix; restore
settings have none.

| Variable            | Default       | Purpose                                                              |
| ------------------- | ------------- | -------------------------------------------------------------------- |
| `MSSQL_SA_PASSWORD` | —             | `sa` password. **Must** meet SQL Server's policy (see below).        |
| `MSSQL_IMAGE`       | see below     | Image for `mssql` and `restore-mssql`.                               |
| `MSSQL_PORT`        | `1433`        | Host port to publish (not `MSSQL_TCP_PORT`, the in-container port).  |
| `MSSQL_DATABASE`    | —             | Name to restore the backup as.                                       |
| `BAK_FILE`          | —             | File name inside `baks/`. Required when there's more than one.       |
| `BAK_FILE_POSITION` | —             | Backup set (`FILE = n`). Required when the file holds more than one. |
| `DB_USER_LOGINS`    | —             | `user:login,user:login` — remap restored users to existing logins.   |

The admin user is always `sa`.

`MSSQL_SA_PASSWORD` becomes the `sa` password, so SQL Server enforces its policy on it: at
least 8 characters, using 3 of these 4 groups — uppercase, lowercase, digits, symbols. The
value in `.env.example` satisfies the policy but is a placeholder; change it.

The database is restored under the name in **`MSSQL_DATABASE`**, not the name it had inside
the backup. A `sales_prod_20240101.bak` will come up as `mydb` unless you say otherwise.

## Services

| Service         | Purpose                                                            |
| --------------- | ------------------------------------------------------------------ |
| `mssql`         | The SQL Server instance. Data persists in the `mssql_data` volume. |
| `restore-mssql` | One-shot restore of the backup in `baks/`, then exits.             |

`restore-mssql` waits for `mssql` to pass its healthcheck before running, and does not restart.

Both use `MSSQL_IMAGE`, which defaults to `mcr.microsoft.com/mssql/server:2022-CU27-GDR1-ubuntu-22.04`
(`@@VERSION` 16.0.4305.5). It's a fixed CU tag rather than `2022-latest`, so a pull never
changes the server version under you. Bump it on purpose, and never below the version a
volume was last started with. The healthcheck and the restore script both call
`/opt/mssql-tools18/bin/sqlcmd`, which not every image ships (2019 images have
`/opt/mssql-tools/bin/sqlcmd`, without the `18`), so check that path before switching tags.

`restore-mssql` builds from `restore-mssql.Dockerfile` instead of using that image directly —
it's the same base, plus `unzip` installed at build time (as root, before the image drops to
the non-root `mssql` user). That's needed to extract a `.bak` that's actually a ZIP (see
below); the container itself can't `apt-get install` anything at runtime since it runs as
`mssql`, not root.

## Edition and feature limits

The image runs **Developer Edition** (engine edition 3, `16.0.4305.5`). It carries the full
Enterprise feature set, but it is **licensed for development and test only — not production**.
`MSSQL_PID` selects a different edition (`Express`, `Standard`, `Enterprise`).

Some features are off or absent in the container image:

| Feature              | State                      | Notes                                        |
| -------------------- | -------------------------- | -------------------------------------------- |
| SQL Server Agent     | disabled by default        | Enable with `MSSQL_AGENT_ENABLED=true`.      |
| Change Data Capture  | present, needs the Agent   | See below.                                   |
| Full-Text Search     | not installed              | `SERVERPROPERTY('IsFullTextInstalled')` = 0. |
| FileStream           | off                        | `FilestreamEffectiveLevel` = 0.              |
| PolyBase             | not installed              | `SERVERPROPERTY('IsPolyBaseInstalled')` = 0. |
| CLR integration      | disabled                   | Disables update masks in CDC `net_changes`.  |

**CDC ships with the image, but needs the Agent.** `sys.sp_cdc_enable_db` succeeds either way, so
a database reports `is_cdc_enabled = 1` even with the Agent off — yet the capture and cleanup jobs
CDC depends on are SQL Agent jobs, so nothing is actually captured. Add to `.env`:

```
MSSQL_AGENT_ENABLED=true
```

`env_file` passes it straight through, so no Compose change is needed. With the Agent on,
enabling a table for CDC creates and starts `cdc.<db>_capture` and `cdc.<db>_cleanup`.

## How the restore works

`scripts/restore-db.sh` runs inside `restore-mssql`, and is safe to run on every
`docker compose up`:

1. Looks up the state of `$MSSQL_DATABASE` in `sys.databases`:
   - **ONLINE** — logs `✅ ... already ONLINE — skipping restore` and exits `0` without
     touching anything.
   - **RECOVERING** — normal right after a server restart; waits up to 5 minutes for it
     to settle.
   - **Any other state** (e.g. `RESTORING` left by an interrupted restore) — logs a `⚠️`
     with the state, drops the database, and restores it again.
   - **Missing** — restores it.
2. Picks the backup in `/var/opt/mssql/backup` (the `baks/` mount), one level deep: the file
   named by `BAK_FILE`, or else the only `*.bak`/`*.zip` there. With several candidates and
   no `BAK_FILE`, it fails and lists them.
3. If the file starts with the ZIP signature (`PK`), whatever its extension, extracts its
   single `.bak` entry to `/var/opt/mssql/restore-scratch` on the data volume — a path the
   `mssql` server process can read. The file in `baks/` is never modified, and the scratch
   directory is deleted when the script exits.
4. Lists the backup sets with `RESTORE HEADERONLY`. With more than one and no
   `BAK_FILE_POSITION`, it fails and lists Position / BackupType / DatabaseName /
   BackupFinishDate.
5. Reads the files of that set via `RESTORE FILELISTONLY` and builds a `MOVE` clause for each
   under `/var/opt/mssql/data/`, prefixed with the database name so two restores never
   collide:
   - data → `<db>_<LogicalName>.mdf` (`.ndf` unless the original was `.mdf`)
   - log → `<db>_<LogicalName>.ldf`
   - FileStream / In-Memory OLTP container → directory `<db>_<LogicalName>`, with a warning:
     In-Memory OLTP restores fine, FileStream doesn't (it's off in this image)
   - Full-Text catalog → fails upfront (Full-Text isn't installed)
6. Runs `RESTORE DATABASE [$MSSQL_DATABASE] ... WITH FILE = n, <moves>, STATS = 10, RECOVERY`,
   logging progress every 10%.
7. Remaps each `DB_USER_LOGINS` pair with `ALTER USER ... WITH LOGIN = ...` when the login
   exists, then lists the remaining orphaned users — SQL and Windows users whose SID matches no
   login on this server. Problems here only warn: the database is already restored.

All names are escaped before they go into T-SQL, so database, logical and file names with
quotes or brackets are safe.

## Safety

- The files in `baks/` are never renamed, modified or deleted; ZIPs are extracted to a
  scratch directory that's removed on exit.
- The password is never on a command line: `SQLCMDPASSWORD` carries it for the healthcheck,
  the restore script and `docker compose exec`, and it is never logged.
- An ONLINE database is never touched. Only a database stuck in a non-ONLINE state is dropped
  and restored again.
- User remapping only targets logins that already exist; the script never creates logins.

## Using it with other containers

By default the stack creates its own network and the server is reachable from the host at
`localhost:${MSSQL_PORT}`. If you have other containers — an API, a worker — that should
reach it by hostname instead, join them on a shared external network:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
# uncomment the "Join an existing network" block and set your network name
docker network create my-shared-network
```

Other containers on that network then connect to host `mssql`, port `1433`.

`docker-compose.override.yml` is git-ignored, so machine-specific wiring never lands in the
repo. The example file also covers pinning container names and the volume name.

## Troubleshooting

**`mssql` starts and immediately exits.** Almost always a `MSSQL_SA_PASSWORD` that fails SQL
Server's password policy. The error only shows up in the container log:

```bash
docker compose logs mssql   # look for "Unable to set system administrator password"
```

**`❌ No .bak or .zip file found in baks/`.** `baks/` is empty, or the backup is in a
subdirectory. The script only looks one level deep — move the file directly into `baks/`.

**`❌ Found N backups in baks/`.** Set `BAK_FILE` in `.env` to the file name to restore, or
keep just one backup in `baks/`.

**`❌ The backup holds N backup sets`.** The file has several backups appended to it. Pick one
from the listed positions with `BAK_FILE_POSITION` — usually the latest full backup
(`BackupType` `1`).

**`⚠️ Database ... is RESTORING, not ONLINE`.** A previous restore was interrupted, or the
database was restored `WITH NORECOVERY`. The script drops it and restores again on its own.

**`⚠️ Orphaned users`.** The backup's database users point to logins (by SID) that don't
exist on this server. Create the login and map the user:

```sql
CREATE LOGIN [app_login] WITH PASSWORD = N'...';
USE [mydb];
ALTER USER [app_user] WITH LOGIN = [app_login];
```

Add `DB_USER_LOGINS=app_user:app_login` to `.env` so future restores map it automatically.

**`The database was backed up on a server running version ...`.** The backup comes from a
newer SQL Server than `MSSQL_IMAGE`. Point `MSSQL_IMAGE` at a matching or newer version —
SQL Server can't restore backups from newer versions.

**Force a re-restore.** The script skips when the database is ONLINE, so drop it first:

```bash
docker compose exec mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa \
  -Q "ALTER DATABASE [mydb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [mydb];"
docker compose up -d restore-mssql
```

**Start completely from scratch.** This discards all data:

```bash
docker compose down -v
docker compose up -d
```

## License

[MIT](LICENSE)
