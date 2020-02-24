#!/bin/bash
#set -x
# Variable assignment
PWD=`pwd`
source $PWD/functions.sh
source $PWD/../config/config.file
local_user=$USER
NOW=$(date +"%Y_%m_%d_%I_%M_%p"); today=$(date +"%Y_%m_%d")
LOGFILE="log-$NOW.log"
ERRFILE="err-$NOW.err"
log_file=$PWD/../log/$LOGFILE
err_file=$PWD/../errors/$ERRFILE

# Get the values  from the arguments
while getopts 'h:l:r:u:g:a:' OPTION; do
  case "$OPTION" in
    h)
      host="$OPTARG"
      ;;

    l)
      local_dir="$OPTARG"
      ;;

    r)
      remote_dir="$OPTARG"
      ;;

    u)
      username="$OPTARG"
      ;;

    a)
      action="$OPTARG"
      ;;

    ?)
      echo "Input arguments parsing error"
      exit 1
      ;;
  esac
done

# make pull as default functionality, if action is not mentioned
if [ -z "$action" ] ;then    action="pull"; fi


# Do prechecks before the sync
if [ $action == "prechecks" ]; then
 check_ssh_connectivity $host
 check_hostentry $host
 check_login $username $host
 check_folder_local $local_dir $local_user
 check_folders_remote $username $host $remote_dir
 if [ ! $ignore_process == "yes" ]
  then
     check_process_remote $username $host $remote_dir
     check_process_local $local_dir
 fi
 exit 0
fi

# Acquires lock and start the sync process
set -C
lockfile="$PWD/../config/sync.lock"
if echo "$$" > "$lockfile"; then
    echo "Successfully acquired lock"
    set +C
    sync
    return_val=$?
    mv $lockfile $lockfile-$NOW
    if [ ! $return_val == 0 ] ; then exit 1; fi
else
    echo "Cannot acquire lock - already locked by $(cat "$lockfile")"
    exit 1
fi

# removes SSH banners from error host_file

[ -f $err_file ] && grep -vxFf $PWD/../config/banner.txt $err_file >/tmp/tmp-$NOW.err ;cat /tmp/tmp-$NOW.err >$err_file ;rm /tmp/tmp-$NOW.err


#Removes the log and error files older than 30 days.
if ! cat $PWD/../config/log_clean.file | grep $today >/dev/null ; then
  find $PWD/../log -type f -name '*.log' -mtime +$clean_log -exec rm {} \;
  find $PWD/../errors -type f -name '*.err' -mtime +$clean_log -exec rm {} \;
  echo "Logs Cleaned today: $today" >>$PWD/../config/log_clean.file
fi
