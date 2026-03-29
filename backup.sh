#!/usr/bin/env bash

set -uo pipefail

usage() {
    echo "Usage: $0 <config-file>"
}

write_log_line() {
    local message=$1

    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$message" | tee -a "$LOGFILE"
    else
        echo "$message"
    fi
}

log() {
    if [[ $# -gt 0 ]]; then
        write_log_line "$(date +'%b %d %T') $*"
        return 0
    fi

    local line
    while IFS= read -r line || [[ -n $line ]]; do
        write_log_line "$(date +'%b %d %T') $line"
    done
}

define_default_hook() {
    local hook_name=$1

    if ! declare -F "$hook_name" >/dev/null; then
        eval "$hook_name() { return 0; }"
    fi
}

backup_cmd_is_array() {
    local declaration

    declaration=$(declare -p BACKUP_CMD 2>/dev/null) || return 1
    [[ $declaration == declare\ -a* ]]
}

backup_cmd_defined() {
    if backup_cmd_is_array; then
        [[ ${#BACKUP_CMD[@]} -gt 0 ]]
    else
        [[ -n "${BACKUP_CMD:-}" ]]
    fi
}

backup_cmd_display() {
    local rendered=""

    if backup_cmd_is_array; then
        printf -v rendered '%q ' "${BACKUP_CMD[@]}"
        echo "${rendered% }"
    else
        echo "$BACKUP_CMD"
    fi
}

run_hook() {
    local hook_name=$1
    local status=0

    log "Running: $hook_name"
    "$hook_name" 2>&1 | log
    status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
        log "$hook_name exited with non-zero status: $status"
    fi
    return "$status"
}

run_backup_command() {
    local status=0

    log "Running: $(backup_cmd_display)"
    if backup_cmd_is_array; then
        "${BACKUP_CMD[@]}" 2>&1 | log
    else
        eval -- "$BACKUP_CMD" 2>&1 | log
    fi
    status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
        log "Backup command exited with non-zero status: $status"
    fi
    return "$status"
}

handle_failure() {
    trap - INT TERM HUP
    log "quitting backup"

    if [[ $POST_BACKUP_DONE -eq 0 ]]; then
        run_hook post_backup_command || true
        POST_BACKUP_DONE=1
    fi

    if [[ $FAILED_DONE -eq 0 ]]; then
        run_hook failed_backup_command || true
        FAILED_DONE=1
    fi

    exit 1
}

retry_backup_command() {
    local retries=$NUM_TRIES
    local sleep_time=$SLEEPTIME
    local status=0

    while true; do
        run_backup_command
        status=$?
        if [[ $status -eq 0 ]]; then
            return 0
        fi

        if [[ $retries -le 0 ]]; then
            log "Retries exhausted"
            return "$status"
        fi

        retries=$((retries - 1))
        log "Retries remaining: $retries"
        log "Sleep for $sleep_time seconds"
        sleep "$sleep_time"
        sleep_time=$((sleep_time * 2))
    done
}

prepare_logfile() {
    local logfile_dir

    if [[ -z "${LOGFILE:-}" ]]; then
        return 0
    fi

    logfile_dir=$(dirname -- "$LOGFILE")
    if [[ $logfile_dir != "." ]]; then
        mkdir -p -- "$logfile_dir"
    fi
}

maintain_logs() {
    local compress_after_days=${LOG_COMPRESS_DAYS:-1}
    local keep_days=${LOG_KEEP_DAYS:-90}
    local compressor="gzip"
    local log_path

    if [[ -z "${LOGDIR:-}" || ! -d "${LOGDIR}" ]]; then
        return 0
    fi

    if [[ $(uname) == "Darwin" ]]; then
        return 0
    fi

    if command -v pigz >/dev/null 2>&1; then
        compressor="pigz --rsyncable"
    fi

    log "Removing old log files from $LOGDIR"
    find "$LOGDIR" -maxdepth 1 -type f -mtime +"$keep_days" -print -delete | log

    log "Compressing old log files from $LOGDIR"
    while IFS= read -r -d '' log_path; do
        log "Compressing $log_path"
        $compressor -- "$log_path" 2>&1 | log
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            return 1
        fi
    done < <(find "$LOGDIR" -maxdepth 1 -type f -mtime +"$compress_after_days" ! -name '*.gz' -print0)
}

main() {
    local config_file=${1:-}
    local backup_status=0
    local nounset_was_enabled=0

    if [[ $# -ne 1 || -z $config_file ]]; then
        usage
        exit 1
    fi

    if [[ ! -r $config_file ]]; then
        echo "Config file is not readable: $config_file" >&2
        exit 1
    fi

    if [[ $- == *u* ]]; then
        nounset_was_enabled=1
        set +u
    fi

    # shellcheck disable=SC1090
    source "$config_file"

    if [[ $nounset_was_enabled -eq 1 ]]; then
        set -u
    fi

    NUM_TRIES=${NUM_TRIES:-4}
    SLEEPTIME=${SLEEPTIME:-20}

    define_default_hook pre_backup_command
    define_default_hook post_backup_command
    define_default_hook failed_backup_command
    define_default_hook successful_backup_command

    if ! backup_cmd_defined; then
        log "No backup command defined"
        exit 1
    fi

    prepare_logfile

    if [[ -n "${SET_ULIMIT:-}" && ${SET_ULIMIT:-0} -gt 0 ]]; then
        ulimit -n "$SET_ULIMIT"
    fi

    POST_BACKUP_DONE=0
    FAILED_DONE=0
    trap handle_failure INT TERM HUP

    maintain_logs || handle_failure

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "Dry run"
        declare -f pre_backup_command
        printf '%s\n' "$(backup_cmd_display)"
        declare -f post_backup_command
        declare -f successful_backup_command
        declare -f failed_backup_command
        return 0
    fi

    run_hook pre_backup_command || handle_failure

    retry_backup_command
    backup_status=$?

    run_hook post_backup_command || true
    POST_BACKUP_DONE=1

    if [[ $backup_status -ne 0 ]]; then
        run_hook failed_backup_command || true
        FAILED_DONE=1
        exit "$backup_status"
    fi

    run_hook successful_backup_command || handle_failure
    log "done"
}

main "$@"
