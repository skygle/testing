#!/bin/bash
#set -x

# Functions
# Check file exists
function file_exists() {
  for var in "$@"
  do
   if [ -f "$var" ]
   then
  	 echo "$var found."
   else
  	 echo "$var not found. Exiting from the program"
     exit 1
   fi
 done
}

# Check passed variavle is null or not
function variable_check() {
 for var in "$@"
 do
  if [ -z "$var" ]
  then
      echo "\$var is empty"
      return 1
  else
      return 0
  fi
 done
}

#Check SSH connectivity with remote server
function check_ssh_connectivity() {
  host=$1
  if nc -z $host 22 2>/dev/null; then
      printf "\033[1;32m Server $host is reachable \033[0m \n"
  else
      printf "\033[0;31m $host is not reachable \033[0m \n"
      exit 1
  fi
}

# Checks the localhost has the entry for remote host in known_host file
function check_hostentry() {
  host=$1
  if cat ~/.ssh/known_hosts | grep $host > /dev/null
  then
    printf "\033[1;32m Host entry exists \033[0m \n"
  else
   ssh-keyscan $host >> ~/.ssh/known_hosts
  fi
}

# Check user able to the server using ssh passwordless connectivity
function check_login() {
  username=$1
  host=$2
  ssh -q $username@$host exit &
  process_id=$!
  wait $process_id
  if [ ! $? == 0 ] ; then
    printf "\033[0;31m SSH Login failed. Exiting from program \033[0m  \n"
    exit 1
  fi
}

# Check the remote destination folders are present
function check_folders_remote() {
  username=$1
  host=$2
  remote_dir=$3
  ssh -q $username@$host /usr/bin/bash << EOF
  if [ -d "$remote_dir" ]; then
    printf "\033[1;32m Directory Is present \033[0m  \n"
  else
    printf "\033[0;31m Remote Directory is not Present. Please check the destination directory \033[0m  \n"
  fi
EOF
}

# Check the local folder exists or not.
function check_folder_local() {
  local_dir=$1
  local_user=$2
  if [ ! -d "$local_dir" ]; then
    printf "\033[0;31m Directory is not present \033[0m   \n"
    exit 1
  fi
  if [ "$EUID" -ne 0 ] ; then
    file_count=`find $local_dir \! -user $local_user -print | wc -l`
    if [ $file_count == 0 ] ; then
      printf "\033[1;32m Files Owned by the current user, continuing file sync \033[0m  \n"
    else
      printf "\033[0;31m Some files owned by the other user, please correct permission \033[0m   \n"
      exit 1
    fi
  fi
}

# Check any process running on remote server
function check_process_remote() {
  username=$1
  host=$2
  remote_dir=$3
  ssh -q $username@$host /usr/bin/bash << EOF
  remotep=`ps -d | grep $remote_dir | wc -l`
  if [ "\$remotep" -gt 1 ]; then printf "\033[0;31m There is a process running in the remote server, Please stop that \033[0m   \n"; exit 1;fi
EOF
}

# Check any process running on Local server
function check_process_local() {
  local_dir=$1
  localp=`ps -d | grep $local_dir | wc -l`
  if [ "$localp" -gt 1 ]; then printf "\033[0;31m There is a process running in the Local server, Please stop that \033[0m   \n"; exit 1;fi
}

# main function for sync functionality.
function sync() {
  if [ $action == "push" ]; then   src=$local_dir; destination="$username@$host:$remote_dir"; fi
  if [ $action == "pull" ]; then   destination=$local_dir; src="$username@$host:$remote_dir"; fi
  rsync --inplace -auzP  -e ssh $src/*  $destination  >$log_file 2>$err_file &
  process_id=$!
  LAST_COMMAND_TIME=$(date +%s)

  a=0
  while [ $a == 0 ]
  do
  #  printf "process still running"
    LAST_COMMAND_DURATION=$(($(date +%s) - ${LAST_COMMAND_TIME}))
    [[ ${LAST_COMMAND_DURATION} -gt $process_long ]] &&  echo "Took long, didnt it?" ; LAST_COMMAND_TIME=$(date +%s)
    sleep 7
    ps -p $process_id >/dev/null
    a=$?
  done

  wait $process_id
  my_status=$?
  if [ $my_status == 0 ] ; then
    printf "\033[1;32m Files copied successfully \033[0m  \n"
  else
    printf "\033[0;31m Files are not copied properly, Please check the error \033[0m   \n"
    return 1
  fi
}
