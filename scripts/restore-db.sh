#!/bin/bash
set -e

echo "⏳ Waiting for SQL Server..."
sleep 5

SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

echo "🔍 Checking whether database '${DB_DATABASE}' already exists..."

DB_EXISTS=$($SQLCMD -C -S mssql -U "$DB_USER" -P "$DB_PASS" -h -1 -Q "
SET NOCOUNT ON;
SELECT COUNT(*) FROM sys.databases WHERE name = '${DB_DATABASE}'
")

if [ $DB_EXISTS != 0 ]; then
  echo "✅ Database '${DB_DATABASE}' already exists — skipping restore."
  exit 0
fi

echo "📦 Looking for a .bak file..."
BAK_PATH=$(find /var/opt/mssql/backup -maxdepth 1 -type f -iname "*.bak" | head -n 1)

if [ -z "$BAK_PATH" ]; then
  echo "❌ No .bak file found"
  exit 1
fi

echo "📦 Using backup: $BAK_PATH"

echo "🔍 Reading FILELIST..."
$SQLCMD -C -S mssql -U "$DB_USER" -P "$DB_PASS" -Q "
RESTORE FILELISTONLY FROM DISK = N'$BAK_PATH'
" -s"," -W > /tmp/filelist.txt

RESTORE_MOVES=""

while IFS=',' read -r LogicalName PhysicalName _; do
  ext="${PhysicalName##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  case "$ext" in
    mdf|ndf)
      path="/var/opt/mssql/data/${LogicalName}.mdf"
      ;;
    ldf)
      path="/var/opt/mssql/data/${LogicalName}_log.ldf"
      ;;
    *)
      continue
      ;;
  esac

  RESTORE_MOVES+="MOVE N'$LogicalName' TO N'$path',"
done < <(tail -n +3 /tmp/filelist.txt)

RESTORE_MOVES=${RESTORE_MOVES%,}

echo "🧩 Generated MOVE clauses:"
echo "$RESTORE_MOVES"

echo "🚀 Restoring database '${DB_DATABASE}'..."

$SQLCMD -C -S mssql -U "$DB_USER" -P "$DB_PASS" -Q "
RESTORE DATABASE [$DB_DATABASE]
FROM DISK = N'$BAK_PATH'
WITH
  $RESTORE_MOVES,
  RECOVERY;
"

echo "✅ Restore complete"
