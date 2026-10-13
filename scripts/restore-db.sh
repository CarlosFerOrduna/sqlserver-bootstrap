#!/bin/bash
set -euo pipefail

SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
BACKUP_DIR="/var/opt/mssql/backup"
DATA_DIR="/var/opt/mssql/data"
# On the shared data volume: RESTORE reads the file from the mssql container, not this one.
SCRATCH_DIR="/var/opt/mssql/restore-scratch"

: "${MSSQL_DATABASE:?MSSQL_DATABASE is not set}"

# No -P: sqlcmd reads the password from SQLCMDPASSWORD.
sql() { "$SQLCMD" -C -S mssql -U sa -b -r1 "$@"; }
sql_string() { printf "N'%s'" "${1//\'/\'\'}"; }
sql_name() { printf '[%s]' "${1//]/]]}"; }
file_safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

query_value() { sql -h -1 -W -Q "SET NOCOUNT ON; $1"; }

# Prints the requested columns of a result set, tab-separated, matched by header name.
query_columns() {
  sql -W -s $'\t' -Q "SET NOCOUNT ON; $2" | awk -F'\t' -v OFS='\t' -v want="$1" '
    NR == 1 { for (i = 1; i <= NF; i++) column[$i] = i; n = split(want, w, ","); next }
    NR == 2 || !NF { next }
    { row = $column[w[1]]; for (j = 2; j <= n; j++) row = row OFS $column[w[j]]; print row }'
}

DB_NAME=$(sql_name "$MSSQL_DATABASE")
DB_LITERAL=$(sql_string "$MSSQL_DATABASE")

rm -rf "$SCRATCH_DIR"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

db_state() { query_value "SELECT state_desc FROM sys.databases WHERE name = $DB_LITERAL"; }

echo "🔍 Checking database '${MSSQL_DATABASE}'..."
state=$(db_state)
# RECOVERING is normal right after a server restart; wait instead of treating it as stuck.
for _ in $(seq 60); do
  [ "$state" = "RECOVERING" ] || break
  sleep 5
  state=$(db_state)
done

case "$state" in
  "") ;;
  ONLINE)
    echo "✅ Database '${MSSQL_DATABASE}' is already ONLINE — skipping restore."
    exit 0
    ;;
  RECOVERING)
    echo "❌ Database '${MSSQL_DATABASE}' is still RECOVERING after 5 minutes — check 'docker compose logs mssql', then run restore-mssql again."
    exit 1
    ;;
  *)
    echo "⚠️ Database '${MSSQL_DATABASE}' is $state, not ONLINE — dropping it and restoring again."
    sql -Q "DROP DATABASE $DB_NAME"
    ;;
esac

if [ -n "${BAK_FILE:-}" ]; then
  BAK_PATH="$BACKUP_DIR/$BAK_FILE"
  if [ ! -f "$BAK_PATH" ]; then
    echo "❌ BAK_FILE '$BAK_FILE' not found in baks/"
    exit 1
  fi
else
  mapfile -t candidates < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -iname '*.bak' -o -iname '*.zip' \) | sort)
  case ${#candidates[@]} in
    0)
      echo "❌ No .bak or .zip file found in baks/"
      exit 1
      ;;
    1) BAK_PATH=${candidates[0]} ;;
    *)
      echo "❌ Found ${#candidates[@]} backups in baks/ — set BAK_FILE to one of:"
      printf '   %s\n' "${candidates[@]##*/}"
      exit 1
      ;;
  esac
fi

echo "📦 Using backup: ${BAK_PATH##*/}"

if [ "$(head -c 2 "$BAK_PATH" | tr -d '\0')" = "PK" ]; then
  echo "📦 '${BAK_PATH##*/}' is a ZIP archive — extracting its .bak (the original is left untouched)..."

  if ! command -v unzip >/dev/null 2>&1; then
    echo "❌ 'unzip' is not available in this image — extract the archive manually and drop the real .bak in baks/."
    exit 1
  fi

  if ! entries=$(unzip -Z1 "$BAK_PATH"); then
    echo "❌ '${BAK_PATH##*/}' is not a readable ZIP archive"
    exit 1
  fi
  mapfile -t bak_entries < <(grep -i '\.bak$' <<<"$entries" || true)

  case ${#bak_entries[@]} in
    0)
      echo "❌ '${BAK_PATH##*/}' contains no .bak file"
      exit 1
      ;;
    1) ;;
    *)
      echo "❌ '${BAK_PATH##*/}' contains ${#bak_entries[@]} .bak files — keep one per archive:"
      printf '   %s\n' "${bak_entries[@]}"
      exit 1
      ;;
  esac

  mkdir -p "$SCRATCH_DIR"
  # The only .bak entry, selected by pattern so unzip never parses the entry name as a wildcard.
  unzip -q -j -C -d "$SCRATCH_DIR" "$BAK_PATH" '*.bak'
  BAK_PATH="$SCRATCH_DIR/${bak_entries[0]##*/}"
  echo "📦 Using extracted backup: ${bak_entries[0]}"
fi

BAK_LITERAL=$(sql_string "$BAK_PATH")

echo "🔍 Reading backup sets..."
if ! headers=$(query_columns "Position,BackupType,DatabaseName,BackupFinishDate" \
  "RESTORE HEADERONLY FROM DISK = $BAK_LITERAL"); then
  echo "❌ RESTORE HEADERONLY failed — the backup is likely corrupt or incomplete"
  exit 1
fi

set_count=$(grep -c . <<<"$headers" || true)

if [ -n "${BAK_FILE_POSITION:-}" ]; then
  position=$BAK_FILE_POSITION
  if ! [[ "$position" =~ ^[0-9]+$ ]] \
    || ! awk -F'\t' -v p="$position" '$1 == p { found = 1 } END { exit !found }' <<<"$headers"; then
    echo "❌ BAK_FILE_POSITION '$position' is not a backup set in this file. Available sets:"
    printf 'Position\tBackupType\tDatabaseName\tBackupFinishDate\n%s\n' "$headers"
    exit 1
  fi
elif [ "$set_count" -eq 1 ]; then
  position=$(cut -f1 <<<"$headers")
else
  echo "❌ The backup holds $set_count backup sets — set BAK_FILE_POSITION to one of:"
  printf 'Position\tBackupType\tDatabaseName\tBackupFinishDate\n%s\n' "$headers"
  exit 1
fi

echo "🔍 Reading FILELIST of backup set $position..."
if ! filelist=$(query_columns "LogicalName,PhysicalName,Type,FileId" \
  "RESTORE FILELISTONLY FROM DISK = $BAK_LITERAL WITH FILE = $position"); then
  echo "❌ RESTORE FILELISTONLY failed — the backup is likely corrupt or incomplete"
  exit 1
fi

if [ -z "$filelist" ]; then
  echo "❌ RESTORE FILELISTONLY returned no files — cannot restore"
  exit 1
fi

db_file=$(file_safe "$MSSQL_DATABASE")
declare -A used_bases=()
moves=()

while IFS=$'\t' read -r logical physical type file_id; do
  base="$DATA_DIR/${db_file}_$(file_safe "$logical")"
  if [ -n "${used_bases[$base]:-}" ]; then
    base+="_$file_id"
  fi
  used_bases[$base]=1

  ext="${physical##*.}"
  case "$type" in
    D)
      if [ "${ext,,}" = "mdf" ]; then path="$base.mdf"; else path="$base.ndf"; fi
      ;;
    L) path="$base.ldf" ;;
    S)
      path="$base"
      echo "⚠️ '$logical' is a FileStream or In-Memory OLTP container — FileStream is off in this image, so a FileStream database will fail to restore."
      ;;
    F)
      echo "❌ '$logical' is a Full-Text catalog, and Full-Text Search is not installed in this image — cannot restore"
      exit 1
      ;;
    *)
      echo "❌ Unknown file type '$type' for '$logical' — cannot restore"
      exit 1
      ;;
  esac

  moves+=("MOVE $(sql_string "$logical") TO $(sql_string "$path")")
done <<<"$filelist"

move_clauses=$(printf '  %s,\n' "${moves[@]}")

echo "🧩 Generated MOVE clauses:"
echo "$move_clauses"

echo "🚀 Restoring database '${MSSQL_DATABASE}'..."

sql -Q "
RESTORE DATABASE $DB_NAME
FROM DISK = $BAK_LITERAL
WITH
  FILE = $position,
$move_clauses
  STATS = 10,
  RECOVERY;
"

echo "✅ Restore complete"

# The database is already restored: from here on, problems only warn.
IFS=',' read -ra user_logins <<<"${DB_USER_LOGINS:-}"
for pair in "${user_logins[@]}"; do
  user="${pair%%:*}"
  login="${pair#*:}"
  if [ "$user" = "$pair" ] || [ -z "$user" ] || [ -z "$login" ]; then
    echo "⚠️ Ignoring DB_USER_LOGINS entry '$pair' — expected user:login"
    continue
  fi

  if ! login_count=$(query_value "SELECT COUNT(*) FROM sys.server_principals WHERE name = $(sql_string "$login")"); then
    echo "⚠️ Could not look up login '$login'"
    continue
  fi
  if [ "$login_count" = "0" ]; then
    echo "⚠️ Login '$login' does not exist — skipping user '$user'. Create the login, then run ALTER USER ... WITH LOGIN = ... by hand."
    continue
  fi

  if sql -d "$MSSQL_DATABASE" -Q "ALTER USER $(sql_name "$user") WITH LOGIN = $(sql_name "$login")"; then
    echo "🔗 Mapped user '$user' to login '$login'"
  else
    echo "⚠️ Could not map user '$user' to login '$login'"
  fi
done

if ! orphans=$(query_value "
SELECT dp.name
FROM $DB_NAME.sys.database_principals AS dp
WHERE dp.type IN ('S', 'U', 'G')
  AND dp.authentication_type IN (1, 3)
  AND dp.principal_id > 4
  AND NOT EXISTS (SELECT 1 FROM sys.server_principals AS sp WHERE sp.sid = dp.sid)
ORDER BY dp.name
"); then
  echo "⚠️ Could not check for orphaned users"
  exit 0
fi

if [ -n "$orphans" ]; then
  echo "⚠️ Orphaned users (no matching login on this server):"
  mapfile -t orphan_list <<<"$orphans"
  printf '   %s\n' "${orphan_list[@]}"
  echo "   Create a login for each (CREATE LOGIN), then map it with ALTER USER ... WITH LOGIN = ...,"
  echo "   or set DB_USER_LOGINS=user:login so future restores map it automatically."
fi
