#!/bin/bash
#set -x
# Variable initialization and Arguments assignment

PWD=`pwd`
host=$1 ;user=$2;file=$3;action=$4

# import functions from the script
source $PWD/functions.sh || (printf "Functions file is not there. Please check"; exit 1)

# Variable validations
variable_check $host $user $file $action
file_exists  $file
sed -i '/^$/d' $file


# Read the file and call the sync script with file contents
grep -v '^#' $file | while read -r a
do
  exc_dir=""
  base_dir=`echo $a |awk -F, '{print $1}'`
  local_dir=$base_dir; remote_dir=$base_dir
 $PWD/sync.sh -h $host -u $user -l $local_dir -r $remote_dir -a $action
 if [ ! $? == 0 ] ; then
   printf "\033[0;31m Unable to sync One of the directory, exiting from program \033[0m  \n"
   exit 1
 fi
done
