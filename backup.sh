#!/bin/bash

CURRENT_USER=$(id -un)

MYSQL_OS_USER=$(ps -ef | awk '/[m]ysqld/ { print $1; exit }')

if [ "$CURRENT_USER" != "$MYSQL_OS_USER" ]; then
    case "$0" in
        /*) SCRIPT_PATH=$0 ;;
        *) SCRIPT_PATH=$(pwd)/$0 ;;
    esac

    # 1. Test sudo capability
    if command -v sudo >/dev/null 2>&1 && sudo -n -u "$MYSQL_OS_USER" true >/dev/null 2>&1; then
        echo "--> sudo test passed. Executing with sudo..."
        exec sudo -u "$MYSQL_OS_USER" /bin/bash "$SCRIPT_PATH" "$@"

    # 2. Test runuser capability (Preferred for root user)
    elif command -v runuser >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && runuser -u "$MYSQL_OS_USER" -- true >/dev/null 2>&1; then
        echo "--> runuser test passed. Executing with runuser..."
        exec runuser -u "$MYSQL_OS_USER" -- /bin/bash "$SCRIPT_PATH" "$@"

    # 3. Test su capability
    elif command -v su >/dev/null 2>&1 && su -s /bin/bash "$MYSQL_OS_USER" -c "true" >/dev/null 2>&1; then
        echo "--> su test passed. Executing with su..."
        # Safely preserve arguments when using su -c
        exec su -s /bin/bash "$MYSQL_OS_USER" -c "$SCRIPT_PATH"

    # 4. Fallback failure if none pass verification
    else
        echo "Error: None of the user-switching tools (sudo, runuser, su) passed validation to switch to '$MYSQL_OS_USER'." >&2
    fi
fi

# Initialize empty debug string
DEBUG_FLAG="Y"
DEBUG_INFO=""
if [ "$DEBUG_FLAG" = "Y" ]; then
  DEBUG_INFO="$MYSQL_OS_USER | $CURRENT_USER"
fi

# Output Directory
OUTPUT_DIR="/tmp"

if [ -w "/tmp" ]; then
  echo "User has write access to /tmp"
else
  echo "User does NOT have write access to /tmp"
  if [ "$DEBUG_FLAG" = "Y" ]; then
    DEBUG_INFO="${DEBUG_INFO:+$DEBUG_INFO | }tmp_not_writable "
  fi
fi

if command -v mysqld >/dev/null 2>&1; then
    MYSQLD=$(command -v mysqld)
elif pgrep -x mysqld >/dev/null 2>&1; then
    MYSQLD=$(readlink -f /proc/$(pgrep -x mysqld | head -n1)/exe 2>/dev/null)
elif [ -z "$MYSQLD" ]; then
    # List fixed paths as well as glob patterns (e.g. /usr/mysql/*/bin/mysqld)
    for path in \
        /usr/sbin/mysqld \
        /usr/libexec/mysqld \
        /usr/bin/mysqld \
        /usr/local/mysql/bin/mysqld \
        /usr/local/bin/mysqld \
        /opt/mysql/server/bin/mysqld \
        /opt/mysql/bin/mysqld \
        /opt/mariadb/bin/mysqld \
        /usr/mariadb/bin/mysqld \
        /usr/mysql/*/bin/mysqld; do

        if [ -x "$path" ]; then
            MYSQLD="$path"
            break
        fi
    done
fi

if [ -z "$MYSQLD" ]; then
  echo "Mysqld path not found"
  if [ "$DEBUG_FLAG" = "Y" ]; then
    DEBUG_INFO="${DEBUG_INFO:+$DEBUG_INFO | }mysqld_notfound "
  fi
fi


MYSQLD_PID=$(pgrep -x mysqld | head -n1)
if [ -n "$MYSQLD_PID" ]; then
    MYSQLD_TMP=$(readlink -f "/proc/$MYSQLD_PID/exe" 2>/dev/null)
    MYSQL_DIR=$(dirname "$MYSQLD_TMP")
fi

if command -v mysql >/dev/null 2>&1; then
    MYSQL=$(command -v mysql)
elif [[ -x "$MYSQL_DIR/mysql" ]]; then
    MYSQL="$MYSQL_DIR/mysql"
elif [[ -x "$MYSQL_DIR/../bin/mysql" ]]; then
    MYSQL="$MYSQL_DIR/../bin/mysql"
elif [ -z "$MYSQL" ]; then
   for path in \
        /usr/bin/mysql \
        /usr/sbin/mysql \
        /usr/local/bin/mysql \
        /usr/local/sbin/mysql \
        /usr/libexec/mysql \
        /usr/local/mysql/bin/mysql \
        /opt/mysql/bin/mysql \
        /opt/mysql/server/bin/mysql \
        /usr/mariadb/bin/mysql \
        /opt/mariadb/bin/mysql \
        /usr/percona/bin/mysql \
        /opt/percona/bin/mysql \
        /opt/rh/rh-mysql*/root/usr/bin/mysql \
        /opt/rh/rh-mariadb*/root/usr/bin/mysql \
        /usr/mysql/*/bin/mysql \
        /snap/bin/mysql; do

        if [ -x "$path" ]; then
            MYSQL="$path"
            break
        fi
    done
fi


if [ ! -x "$MYSQL" ] && [ "$DEBUG_FLAG" = "Y" ]; then
    DEBUG_INFO="${DEBUG_INFO:+$DEBUG_INFO | }mysql_notfound"
fi

OUT_FILE="$OUTPUT_DIR/mysql_backup_report_7days.tsv"
CSV_FILE="$OUTPUT_DIR/mysql_backup_report_7days.csv"



SCRIPT=$(awk '{print $NF}' /dba/scripts/database_jobs.txt 2>/dev/null)
echo "$SCRIPT"

BACKUP_DEVICE=$(grep '^export DUMPDIR=' "$SCRIPT" 2>/dev/null | cut -d= -f2 | tr -d '"')
echo "$BACKUP_DEVICE"

cron_output=$(crontab -l -u mysql 2>/dev/null | grep -i backup)
echo "$cron_output"

DBVERSION=$("$MYSQLD" --version 2>/dev/null | awk '{print $3}' | cut -d- -f1)

RDBMS="MySQL"
HOSTNAME_FQDN=$(hostname -s)
SERVERNAME="$HOSTNAME_FQDN"
INSTANCENAME="MySQL Server"

STATE_DESC="OFFLINE"

if pgrep mysqld >/dev/null 2>&1; then
    STATE_DESC="ONLINE"
fi
DBRMODE=""

# DATE FORMATTER
fmt_date () {
    if [[ -z "${1:-}" || "$1" == "-" ]]; then
        echo ""
    else
        date -d "$1" '+%-m/%-d/%Y %I:%M:%S %p' 2>/dev/null || echo ""
    fi
}

# QUOTE HANDLER
q() {
    [ -z "${1:-}" ] && printf '""' || printf '"%s"' "$1"
}

VERSION_STR=$("$MYSQLD" --version 2>/dev/null)

if echo "$VERSION_STR" | grep -qi 'enterprise'; then
    EDITION="Enterprise Server"
elif [ -n "$VERSION_STR" ]; then
    EDITION="Community Server"
fi

echo "RDBMS: $RDBMS"
echo "DBVERSION: $DBVERSION"
echo "EDITION: $EDITION"

if ! $MYSQL -Nse "SELECT 1;" >/dev/null 2>&1; then
  echo "Mysql login not working"
  if [ "$DEBUG_FLAG" = "Y" ]; then
    DEBUG_INFO="${DEBUG_INFO:+$DEBUG_INFO | }login_ntwork "
  fi
fi

SRVCOLLATION=$($MYSQL -Nse "SELECT @@character_set_server;" 2>/dev/null | tr '\t\n' ' ')

rm -f "$OUT_FILE"
touch "$OUT_FILE" || OUT_FILE="/tmp/mysql_backup_report_$$.tsv"

# HEADER (QUOTED)
echo -e "\"rdbms\"\t\"hostname\"\t\"servername\"\t\"instancename\"\t\"dbversion\"\t\"edition\"\t\"srvcollation\"\t\"datekey\"\t\"dbname\"\t\"state_desc\"\t\"dbrmode\"\t\"totalsizemb\"\t\"datasizemb\"\t\"logsizemb\"\t\"fullbkstart\"\t\"fullbkfinish\"\t\"fullbksizemb\"\t\"fullbkcompMB\"\t\"fullbkdevice\"\t\"toolused\"\t\"incbkstart\"\t\"incbkfinish\"\t\"incbksizemb\"\t\"incbkcompmb\"\t\"incbkdevice\"\t\"nologbkps\"\t\"totlgbkpsizemb\"\t\"logbkstart\"\t\"logbkfinish\"\t\"logbksizemb\"\t\"logbkcompmb\"\t\"logbkdevice\"\t\"collectedDate\"\t\"remarks\"" >> "$OUT_FILE"

# DB SIZE
declare -A TOTAL_MB DATA_MB
while read -r db t d; do
    TOTAL_MB["$db"]="$t"
    DATA_MB["$db"]="$d"
done < <(
$MYSQL -Nse "
SELECT table_schema,
ROUND(SUM(data_length+index_length)/1024/1024, 2),
ROUND(SUM(data_length)/1024/1024, 2)
FROM information_schema.tables
GROUP BY table_schema;" 2>/dev/null
)

# LOG SIZE
LOG_FILE_SIZE=$($MYSQL -Nse "SHOW VARIABLES LIKE 'innodb_log_file_size';" 2>/dev/null | awk '{print $2}')
LOG_FILES_GROUP=$($MYSQL -Nse "SHOW VARIABLES LIKE 'innodb_log_files_in_group';" 2>/dev/null | awk '{print $2}')

LOG_SIZE_MB=""
if [[ -n "$LOG_FILE_SIZE" && -n "$LOG_FILES_GROUP" ]]; then
    LOG_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", ($LOG_FILE_SIZE * $LOG_FILES_GROUP) /1024/1024}")
fi

# BINLOG
BINLOG_BASE=$($MYSQL -Nse "SHOW VARIABLES LIKE 'log_bin_basename';" 2>/dev/null | awk '{print $2}')

if [[ -n "$BINLOG_BASE" ]]; then
    LOGBK_DEVICE=$(dirname "$BINLOG_BASE")
else
    LOGBK_DEVICE=""
fi

LOG_ARRAY=()

if [[ -n "$BINLOG_BASE" ]]; then
    for f in ${BINLOG_BASE}.*; do
        [[ -f "$f" && "$f" != *.index ]] && LOG_ARRAY+=("$f")
    done
fi

NO_LOGBKPS=${#LOG_ARRAY[@]}
TOTAL_LOG_MB=""

echo "BINLOG_BASE=[$BINLOG_BASE]"
echo "LOGBK_DEVICE=[$LOGBK_DEVICE]"

if [[ $NO_LOGBKPS -gt 0 ]]; then
    FIRST_LOG="${LOG_ARRAY[0]}"
    LAST_LOG=$(ls -1t ${BINLOG_BASE}.* 2>/dev/null | grep -v '\.index$' | head -1)
    LOG_START=$(stat -c %y "$LAST_LOG" 2>/dev/null | cut -d'.' -f1)
    LOG_FINISH="$LOG_START"

    SIZE=0
    for f in "${LOG_ARRAY[@]}"; do
        FILE_SZ=$(stat -c %s "$f" 2>/dev/null || echo 0)
        SIZE=$((SIZE + FILE_SZ))
    done

    TOTAL_LOG_MB=$(awk "BEGIN {printf \"%.2f\", $SIZE/1024/1024}")
else
    LOG_START_FMT="$BK_START_FMT"
    LOG_FINISH_FMT="$BK_FINISH_FMT"
fi

echo "BINLOG_BASE=[$BINLOG_BASE]"
echo "LOGBK_DEVICE=[$LOGBK_DEVICE]"

# CRON LOG DETECTION (RESTORED)
result=$(grep -m1 backup_database_full.sh /var/log/cron 2>/dev/null)
script_path=$(echo "$result" | sed -n 's/.* CMD (\(.*\))/\1/p')

if [[ -n "$script_path" && -f "$script_path" ]]; then
    log_dir=$(grep -E '^export LOGDIR=' "$script_path" | cut -d= -f2 | tr -d '"')
fi

[[ -z "${log_dir:-}" ]] && log_dir=$(find /dba /n01 /var -type d -name logs 2>/dev/null | head -1)

LOG_FILE=$(ls -t "$log_dir"/last_mysqlbackup_log.log* 2>/dev/null | head -1)

[[ -f "$LOG_FILE" ]] && echo "Using log: $LOG_FILE"

# TOOL DETECTION
declare -A TOOL TYPE INC_START INC_FINISH

if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    while read -r line; do
        TS=$(echo "$line" | awk -F'[][]' '{print $2}')

        if [[ "$line" == *"mysqldump of database"* ]]; then
            DB=$(echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="database") print $(i+1)}')
            TOOL["$DB"]="mysqldump"
            TYPE["$DB"]="full"
        fi

        if [[ "$line" == *"completed OK"* ]]; then
            TOOL["ALL_DATABASES"]="xtrabackup"
            TYPE["ALL_DATABASES"]="full"
        fi

        if [[ "$line" == *"incremental"* ]]; then
            INC_START["ALL_DATABASES"]="$TS"
            INC_FINISH["ALL_DATABASES"]="$TS"
            TOOL["ALL_DATABASES"]="xtrabackup"
            TYPE["ALL_DATABASES"]="incremental"
        fi
    done < "$LOG_FILE"
fi

# BACKUP FILE PARSE - LAST 7 DAYS
declare -A START_TIME FINISH_TIME BACKUP_FILE

shopt -s nullglob

if [[ -n "$BACKUP_DEVICE" && -d "$BACKUP_DEVICE" ]]; then
    while IFS= read -r f; do
        file=$(basename "$f")

        DBNAME=$(echo "$file" | sed -E 's/.*mysql_dump_backup_[^_]+_([^_]+)_.*$/\1/')
        TS=$(echo "$file" | grep -oE '[0-9]{6}_[0-9]{4}')

        [[ -z "$TS" ]] && continue

        TS_FMT=$(date -d "20${TS:0:2}-${TS:2:2}-${TS:4:2} ${TS:7:2}:${TS:9:2}:00" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

        KEY="${DBNAME}|$(basename "$f")"

        START_TIME["$KEY"]="$TS_FMT"
        FINISH_TIME["$KEY"]="$TS_FMT"
        BACKUP_FILE["$KEY"]="$f"
    done < <(find "$BACKUP_DEVICE" -type f -name "*.sql.gz" -mtime -7 | sort)
fi

echo "Backup files found: ${#START_TIME[@]}"

if [[ ${#START_TIME[@]} -eq 0 ]]; then
    echo "No backup files found in last 7 days under $BACKUP_DEVICE"

    KEY="ALL_DATABASES|NO_BACKUP"

    START_TIME["$KEY"]=""
    FINISH_TIME["$KEY"]=""
    BACKUP_FILE["$KEY"]=""

    NO_BACKUP_FOUND="Y"
else
    NO_BACKUP_FOUND="N"
fi

# OUTPUT - LAST 7 DAYS
COLLECTION_TIME=$(date '+%Y-%m-%d %H:%M:%S')

for KEY in "${!START_TIME[@]}"; do
    DBNAME="${KEY%%|*}"
    BK_START="${START_TIME[$KEY]}"
    BK_FINISH="${FINISH_TIME[$KEY]}"
    FILE="${BACKUP_FILE[$KEY]}"

    DATEKEY_RAW=$(date '+%Y-%m-%d %H:%M:%S')

    DATEKEY_FMT=$(fmt_date "$DATEKEY_RAW")
    BK_START_FMT=$(fmt_date "$BK_START")
    BK_FINISH_FMT=$(fmt_date "$BK_FINISH")
    LOG_START_FMT=$(fmt_date "$LOG_START")
    LOG_FINISH_FMT=$(fmt_date "$LOG_FINISH")

    COLLECTION_TIME_FMT=$(fmt_date "$COLLECTION_TIME")

    COMP_MB=""
    UNCOMP_MB=""

    if [[ -f "$FILE" ]]; then
        COMP_MB=$(stat -c %s "$FILE" 2>/dev/null | awk '{printf "%.2f", $1/1024/1024}')
        UNCOMP_MB=$(gzip -l "$FILE" 2>/dev/null | awk 'NR==2 {printf "%.2f", $2/1024/1024}')
        REMARKS="SUCCESS"
    else
        REMARKS=""
    fi

    if [[ "$NO_BACKUP_FOUND" == "Y" ]]; then
        DBNAME=""
        BK_START=""
        BK_FINISH=""
        FILE=""
        COMP_MB=""
        UNCOMP_MB=""
        LOG_SIZE_MB=""
        TOOL_USED=""
        TOTAL_LOG_MB=""
        NO_LOGBKPS=""
        LOG_START_FMT=""
        LOG_FINISH_FMT=""
        REMARKS="BACKUP NOT FOUND"
    fi

    if [[ -n "$DEBUG_INFO" ]]; then
        REMARKS="${REMARKS} | ${DEBUG_INFO}"
    fi

    if [[ "$NO_BACKUP_FOUND" != "Y" ]]; then
        TOOL_USED="${TOOL[$DBNAME]}"
        if [[ -z "$TOOL_USED" ]]; then
            TOOL_USED="${TOOL[ALL_DATABASES]}"
        fi
        if [[ -z "$TOOL_USED" ]]; then
            TOOL_USED="mysqldump"
        fi
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(q "$RDBMS")" \
    "$(q "$HOSTNAME_FQDN")" \
    "$(q "$SERVERNAME")" \
    "$(q "$INSTANCENAME")" \
    "$(q "$DBVERSION")" \
    "$(q "$EDITION")" \
    "$(q "$SRVCOLLATION")" \
    "$(q "$DATEKEY_FMT")" \
    "$(q "$DBNAME")" \
    "$(q "$STATE_DESC")" \
    "$(q "$DBRMODE")" \
    "$(q "${TOTAL_MB[$DBNAME]:-}")" \
    "$(q "${DATA_MB[$DBNAME]:-}")" \
    "$(q "$LOG_SIZE_MB")" \
    "$(q "$BK_START_FMT")" \
    "$(q "$BK_FINISH_FMT")" \
    "$(q "$UNCOMP_MB")" \
    "$(q "$COMP_MB")" \
    "$(q "$BACKUP_DEVICE")" \
    "$(q "$TOOL_USED")" \
    "$(q "${INC_START[$DBNAME]:-}")" \
    "$(q "${INC_FINISH[$DBNAME]:-}")" \
    "$(q "0")" \
    "$(q "0")" \
    "$(q "$BACKUP_DEVICE")" \
    "$(q "$NO_LOGBKPS")" \
    "$(q "$TOTAL_LOG_MB")" \
    "$(q "$LOG_START_FMT")" \
    "$(q "$LOG_FINISH_FMT")" \
    "$(q "$TOTAL_LOG_MB")" \
    "$(q "$TOTAL_LOG_MB")" \
    "$(q "$LOGBK_DEVICE")" \
    "$(q "$COLLECTION_TIME_FMT")" \
    "$(q "$REMARKS")" \
    >> "$OUT_FILE"
done

echo "REPORT GENERATED: $OUT_FILE"

if [[ -f "$OUT_FILE" ]]; then
    tr '\t' ',' < "$OUT_FILE" > "$CSV_FILE"
    echo "CSV GENERATED: $CSV_FILE"
else
    echo "ERROR: OUT_FILE not found: $OUT_FILE"
fi
