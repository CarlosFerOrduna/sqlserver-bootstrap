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

## Requirements

- Docker + Docker Compose
- A SQL Server `.bak` file

> Backups are **not** included in this repo, and `.bak` files are git-ignored on purpose:
> they are typically hundreds of MB (GitHub rejects any file over 100 MB) and usually hold
> real data. Keep yours out of version control.

## Quick start

```bash
# 1. Configure
cp .env.example .env
#    edit .env and set DB_PASS (and DB_DATABASE, the name to restore as)

# 2. Drop your backup in
cp /path/to/your-backup.bak baks/

# 3. Start
docker compose up -d

# 4. Watch the restore
docker compose logs -f restore-mssql   # wait for "✅ Restore complete"
```

Then connect from the host:

```bash
sqlcmd -C -S localhost,1433 -U sa -P "<DB_PASS>" -Q "SELECT name FROM sys.databases"
```

## Configuration

All settings live in `.env`:

| Variable      | Default | Purpose                                                         |
| ------------- | ------- | --------------------------------------------------------------- |
| `DB_USER`     | `sa`    | Admin user. The image only supports `sa` for initial bootstrap. |
| `DB_PASS`     | —       | `sa` password. **Must** meet SQL Server's policy (see below).   |
| `DB_DATABASE` | `mydb`  | Name to restore the backup as.                                  |
| `DB_PORT`     | `1433`  | Host port to publish. Change if `1433` is taken.                |

`DB_PASS` becomes the `sa` password, so SQL Server enforces its policy on it: at least
8 characters, using 3 of these 4 groups — uppercase, lowercase, digits, symbols. The value
in `.env.example` satisfies the policy but is a placeholder; change it.

The database is restored under the name in **`DB_DATABASE`**, not the name it had inside the
backup. A `sales_prod_20240101.bak` will come up as `mydb` unless you say otherwise.

## Services

| Service         | Purpose                                                                 |
| --------------- | ----------------------------------------------------------------------- |
| `mssql`         | The SQL Server instance. Data persists in the `mssql_data` volume.      |
| `restore-mssql` | One-shot restore of the first `.bak` found in `baks/`, then exits.      |

`restore-mssql` waits for `mssql` to pass its healthcheck before running, and does not restart.

Both are pinned to `mcr.microsoft.com/mssql/server:2022-latest` on purpose: the healthcheck and
the restore script both call `/opt/mssql-tools18/bin/sqlcmd`, which not every image ships
(2019 images have `/opt/mssql-tools/bin/sqlcmd`, without the `18`). Check that path before
switching tags.

`restore-mssql` builds from `restore-mssql.Dockerfile` instead of using that image directly —
it's the same pinned base, plus `unzip` installed at build time (as root, before the image
drops to the non-root `mssql` user). That's needed to extract a `.bak` that's actually a ZIP
in disguise (see below); the container itself can't `apt-get install` anything at runtime
since it runs as `mssql`, not root.

## Edition and feature limits

The image runs **Developer Edition** (engine edition 3, `16.0.4255.1`). It carries the full
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

1. Checks `sys.databases` for `$DB_DATABASE`. If it already exists, logs
   `✅ Database ... already exists — skipping restore` and exits `0` without touching anything.
2. Picks the **first** `*.bak` in `/var/opt/mssql/backup` (the `baks/` mount), one level deep
   only. With several backups present the choice is not deterministic — keep just one.
3. If the file's first bytes are the ZIP signature (`PK`) — i.e. someone dropped a `.zip` in
   `baks/` and renamed it to `.bak` — extracts it with `unzip`, deletes the `.zip`, and
   continues with the real `.bak` found inside.
4. Reads the logical file names out of the backup via `RESTORE FILELISTONLY`.
5. Builds the `MOVE` clauses so the restored files land under `/var/opt/mssql/data/`:
   `mdf`/`ndf` → `<LogicalName>.mdf`, `ldf` → `<LogicalName>_log.ldf`.
6. Runs `RESTORE DATABASE [$DB_DATABASE] ... WITH <moves>, RECOVERY`.

## Using it with other containers

By default the stack creates its own network and the server is reachable from the host at
`localhost:${DB_PORT}`. If you have other containers — an API, a worker — that should reach
it by hostname instead, join them on a shared external network:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
# uncomment the "Join an existing network" block and set your network name
docker network create my-shared-network
```

Other containers on that network then connect to host `mssql`, port `1433`.

`docker-compose.override.yml` is git-ignored, so machine-specific wiring never lands in the
repo. The example file also covers pinning container names and the volume name.

## Troubleshooting

**`mssql` starts and immediately exits.** Almost always a `DB_PASS` that fails SQL Server's
password policy. The error only shows up in the container log:

```bash
docker compose logs mssql   # look for "Unable to set system administrator password"
```

**`❌ No .bak file found`.** `baks/` is empty, or the backup is in a subdirectory.
The script only looks one level deep — move the file directly into `baks/`.

**Force a re-restore.** The script skips when the database already exists, so drop it first:

```bash
docker compose exec mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "<DB_PASS>" \
  -Q "ALTER DATABASE [mydb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [mydb];"
docker compose up -d restore-mssql
```

**Start completely from scratch.** This discards all data:

```bash
docker compose down -v
docker compose up -d
```
