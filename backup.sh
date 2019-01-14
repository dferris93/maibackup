#!/bin/bash

set -o pipefail

LOG_KEEP_DAYS=90
LOCK_WAIT_TIME="7200"
NUM_TRIES=4
SLEEPTIME=20
LOCKFILE="/usr/bin/lockfile"
LOCK_FILE="/tmp/backup.lck"
LOGFILE="/dev/null"

log ()
{
	if [[ -n $@ ]] 
	then
		echo "$(date +'%b %d %T') $@" | tee -a $LOGFILE 
	else	
		while read -r line
		do
			echo "$(date +'%b %d %T') $line" | tee -a $LOGFILE 
		done
	fi
}

notify () 
{
	if [[ -n $EMAIL ]]
	then
		if [[ -f $LOGFILE ]]
		then
			tail -n 100 $LOGFILE | mail -s "Backup failure on $(hostname)" $EMAIL
		fi
	else	
		echo "Backup failed"
	fi
}

run ()
{
	log "Running: $@"
	$@ 2>&1 | log
	if [[ $? != 0 ]]
	then
		log "$@ exited with non zero status: $?"
		quit
	fi
}

no_quit_run ()
{
	log "Running: $@"
	$@ 2>&1 | log
	if [[ $? != 0 ]]
	then
		log "$@ exited with non zero status: $?"
	fi
}

quit ()
{
    trap '' SIGINT
    log "quitting backup"
    failed_backup_command 2>&1 | log
    no_quit_run notify 
    rm -f $LOCK_FILE
    trap SIGINT
    exit 1
}

lock_quit ()
{
	trap '' SIGINT
	log "Unable to actuire lockfile"
	no_quit_run notify
	trap SIGINT
	exit 1
}

retry ()
{
	RETRIES=$NUM_TRIES
	log "Running: $@"
	while [ true ]
	do
		$@ 2>&1 | log
		if [[ $? != 0 ]]
		then
		    if [[ $RETRIES > 0 ]]
		    then
			RETRIES=$((RETRIES-1))
			log "Retries: $RETRIES"
			log "Sleep for $SLEEPTIME"
			sleep $SLEEPTIME
			SLEEPTIME=$((SLEEPTIME*2))
			continue
		    else
			log "$@ exited with non zero status: $?"
			quit
		    fi
		else
		    break
		fi
	done
}

source $1

if [[ -z $BACKUP_CMD ]]
then
	log "No backup command defined"
	exit 1
fi

ulimit -n 2048

trap lock_quit SIGINT SIGTERM SIGHUP
log "Acquiring lock file $LOCK_FILE" 
$LOCKFILE -$LOCK_WAIT_TIME -r $NUM_TRIES $LOCK_FILE 2> /dev/null  || lock_quit

trap quit SIGINT SIGTERM SIGHUP
log "Removing old log files"
if [ -d $LOGDIR ]
then
	find $LOGDIR -maxdepth 1 -type f -mtime +$LOG_KEEP_DAYS -delete
fi

run pre_backup_command 

retry $BACKUP_CMD

run post_backup_command 

log "Removing $LOCK_FILE" 
rm -f $LOCK_FILE
log "done"
