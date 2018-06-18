#!/bin/bash

set -o pipefail

LOG_KEEP_DAYS=90
LOCK_WAIT_TIME="7200"
NUM_TRIES=4
SLEEPTIME=20
LOCK_FILE="/tmp/backup.lck"

source $1

log ()
{
	echo "$@" | ts >> $LOGFILE
}

run ()
{
	log "Running: $@"
	$@ 2>&1 | ts >> $LOGFILE
	if [[ $? != 0 ]]
	then
		log "$@ exited with non zero status: $?"
		quit $?
	fi
}

quit ()
{
    log "Running failure command..." 
    run failed_backup_command
    log "error command done" 
    tail -n 100 $LOGFILE | mail -s "Backup failure on $(hostname)" $EMAIL
    rm -f $LOCK_FILE
    exit $1
}

retry ()
{
	RETRIES=0
	log "Running: $@"
	while [ true ]
	do
		$@ 2>&1 | ts >> $LOGFILE
		if [[ $? != 0 ]]
		then
		    if [[ $RETRIES < $NUM_TRIES ]]
		    then
			RETRIES=$((RETRIES+1))
			sleep $SLEEPTIME
			SLEEPTIME=$((SLEEPTIME*2))
			continue
		    else
			quit $?
		    fi
		else
		    break
		fi
	done
}

if [ -z $LOGFILE ]
then
	echo "No log file defined"
	exit 1
elif [ -z $DIR ]
then
	echo "No backup root dir defined"
	exit 1
elif [ -z $EMAIL ]
then
	echo "No email address defined"
	exit 1
elif [ -z $LOGDIR ]
then
	echo "No log dir defined"
	exit 1
elif [ -z $DESTINATION ]
then
	echo "No destination defined"
	exit 1
else 
	log "Config looks ok to start"
fi

log "Acquiring lock file $LOCK_FILE" 
run /usr/bin/lockfile -$LOCK_WAIT_TIME -r $NUM_TRIES  $LOCK_FILE

ulimit -n 2048

chmod 700 $DIR

for i in $LOGDIR $ARCHIVEDIR $TEMPDIR
do
    if [ ! -d $i ]
    then
        mkdir $i
    fi
    chmod 700 $i
done


log "Removing old log files" | 
run find $LOGDIR -maxdepth 1 -type f -mtime +$LOG_KEEP_DAYS -delete

log "Running the pre backup command" | 

run pre_backup_command 

trap post_backup_command SIGINT SIGTERM
log "Starting the backup" 
sync
retry $BACKUP_CMD

log "Running the post backup command" 

run post_backup_command 

date "+%s" > $DIR/last_run_time
log "Removing $LOCK_FILE" 
rm -f $LOCK_FILE
log "done"
