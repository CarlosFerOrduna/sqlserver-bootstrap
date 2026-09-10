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

if head -c 2 "$BAK_PATH" | grep -q "PK"; then
  echo "📦 '$BAK_PATH' looks like a ZIP archive — extracting it..."

  if ! command -v unzip >/dev/null 2>&1; then
    echo "❌ 'unzip' is not available in this image — extract '$BAK_PATH' manually and drop the real .bak in baks/."
    exit 1
  fi

  BAK_DIR=$(dirname "$BAK_PATH")
  ZIP_PATH="${BAK_PATH}.zip"
  mv "$BAK_PATH" "$ZIP_PATH"
  unzip -o -q "$ZIP_PATH" -d "$BAK_DIR"
  rm -f "$ZIP_PATH"

  BAK_PATH=$(find "$BAK_DIR" -type f -iname "*.bak" | head -n 1)
  if [ -z "$BAK_PATH" ]; then
    echo "❌ Extracted '$ZIP_PATH' but found no .bak file inside"
    exit 1
  fi

  echo "📦 Using extracted backup: $BAK_PATH"
fi

echo "🔍 Reading FILELIST..."
$SQLCMD -C -S mssql -U "$DB_USER" -P "$DB_PASS" -h -1 -Q "
SET NOCOUNT ON;
RESTORE FILELISTONLY FROM DISK = N'$BAK_PATH'
" -s"," -W > /tmp/filelist.txt

if grep -q "^Msg " /tmp/filelist.txt; then
  echo "❌ RESTORE FILELISTONLY failed — the .bak file is likely corrupt or incomplete:"
  cat /tmp/filelist.txt
  exit 1
fi

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
done < /tmp/filelist.txt

RESTORE_MOVES=${RESTORE_MOVES%,}

echo "🧩 Generated MOVE clauses:"
echo "$RESTORE_MOVES"

if [ -z "$RESTORE_MOVES" ]; then
  echo "❌ No MOVE clauses generated from FILELISTONLY — cannot restore"
  exit 1
fi

echo "🚀 Restoring database '${DB_DATABASE}'..."

$SQLCMD -C -S mssql -U "$DB_USER" -P "$DB_PASS" -Q "
RESTORE DATABASE [$DB_DATABASE]
FROM DISK = N'$BAK_PATH'
WITH
  $RESTORE_MOVES,
  RECOVERY;
"

echo "✅ Restore complete"
