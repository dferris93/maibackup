#!/bin/bash

set -o pipefail

LOG_KEEP_DAYS=90
NUM_TRIES=4
SLEEPTIME=20

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
	eval $@ 2>&1 | log
	if [[ $? != 0 ]]
	then
		log "$@ exited with non zero status: $?"
		quit
	fi
}

quit ()
{
    trap '' SIGINT
    log "quitting backup"
    failed_backup_command 2>&1 | log
    (notify | log)  || log "notify exited with status $?"
    trap SIGINT
    exit 1
}


retry ()
{
	RETRIES=$NUM_TRIES
	log "Running: $@"
	while [ true ]
	do
		sleep 10
		eval $@ 2>&1 | log
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

if [[ $SET_ULIMIT > 0 ]]
then
	ulimit -n $SET_ULIMIT
fi

trap quit SIGINT SIGTERM SIGHUP
if [ -d $LOGDIR ]
then
	if [[ $(uname) != "Darwin" ]]
	then
		log "Removing old log files"
		find $LOGDIR -maxdepth 1 -type f -mtime +$LOG_KEEP_DAYS -delete
	fi
fi

if [[ $DRY_RUN == "true" ]]
then
    type pre_backup_command
    echo $BACKUP_CMD
    type post_backup_command
else
    run pre_backup_command 
    retry $BACKUP_CMD
    run post_backup_command 
fi

log "done"
