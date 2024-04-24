#!/bin/bash

set -o pipefail

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

run ()
{
	log "Running: $@"
	eval $@ 2>&1 | log
	if [[ $? != 0 ]]
	then
		log "$@ exited with non zero status: $?"
		quit
        return 1
    else
        return 0
	fi
}

quit ()
{
    trap '' SIGINT
    log "quitting backup"
    post_backup_command 2>&1 | log
    failed_backup_command 2>&1 | log
    log "failed_backup_command exited with status $?"
    trap SIGINT
    exit 1
}


retry ()
{
	RETRIES=$NUM_TRIES
	log "Running: $@"
	while [[ true ]]
	do
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
                es=$?
                log "$@ exited with non zero status: $es"
                break
		    fi
		else
		    break
            es=0
		fi
	done
    log "returning $es"
    return $es
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
echo "checking $LOGDIR"
if [[ -d $LOGDIR ]]
then
    if [[ -z $LOG_COMPRESS_DAYS ]]
    then
        LOG_COMPRESS_DAYS=1
    fi
    if [[ -z $LOG_KEEP_DAYS ]]
    then
        LOG_KEEP_DAYS=90
    fi
	if [[ $(uname) != "Darwin" ]]
	then
		log "Removing old log files from $LOGDIR"
		find $LOGDIR -maxdepth 1 -type f -mtime +$LOG_KEEP_DAYS -delete
        log "Compress old log files from $LOGDIR"
        if [[ $(ls -l $LOGDIR | wc -l) -gt 0 ]]
        then
            find $LOGDIR -maxdepth 1 -type f -mtime +$LOG_COMPRESS_DAYS | grep -v '\.gz$' | xargs -n 1 pigz --rsyncable 
        fi
	fi
fi

if [[ $DRY_RUN == "true" ]]
then
    type pre_backup_command
    echo $BACKUP_CMD
    if [[ $? -ne 0 ]]
    then
        quit
    else
        type post_backup_command
        type successful_backup_command
    fi
else
    run pre_backup_command 
    retry $BACKUP_CMD
    es=$?
    if [[ $es -ne 0 ]]
    then
        quit
    else
        run post_backup_command 
        run successful_backup_command
    fi
fi

log "done"
