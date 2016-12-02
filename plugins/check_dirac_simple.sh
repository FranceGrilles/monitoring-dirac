#!/bin/bash

# Copyright (C) 2016 CNRS - IdGC - France-Grilles
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Description:
#   Main DIRAC Resource probe.
#
# Changelog:
# v0.1 2016-12-01 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#       Initial Release

PROBE_VERSION="0.1"
DEBUG=true

source /usr/lib/dirac/bashrc
export X509_CERT_DIR=/etc/grid-security/certificates
export X509_USER_CERT=~/.globus/usercert.pem
export X509_VOMS_DIR=/usr/lib/dirac/etc/grid-security/vomsdir
export X509_USER_PROXY=/tmp/x509up_u500
export X509_USER_KEY=~/.globus/userkey.pem

## Workflow
# ---------
# * check_env : 
#       check_proxy
#           if proxy_is_valid < 7 days
#               return STATE_WARNING
#           if proxy_is_valid < 1 day
#               return STATE_CRITICAL
#       check_or_create $TMP_PATH
#       create_jdl
#
# * Create jobs (every 60 min)
#   submit_job:
#       store job_id as a timestamped file in $TMP_PATH
#   submit_job:
#       store job_id as a timestamped file in $TMP_PATH
#       wait 2s
#       delete the job (job will have status=Killed)
#
# * Check jobs (every 60 min)
#   For each job_id in $TMP_PATH, check_job_status :
#   if Status in { Received, Checking, Running, Completed }
#       do_nothing/wait
#       if job_created < 2h
#           return STATE_OK
#       else
#           return STATE_WARNING
#
#   if Status == Done
#       check_job_output
#       if output is expected
#           return STATE_OK
#       else
#           return STATE_CRITICAL
#       delete_job_and_output
#
#   if Status == Deleted
#       if job_is_deleted < 1h
#           return STATE_OK
#       else
#           return STATE_WARNING
#
#   if Status == Waiting
#       do_nothing/wait
#       if job_created < 2h
#           return STATE_OK
#       else
#           return STATE_WARNING
#
#   if Status == Stalled
#       if job_created < 2h
#           delete_job
#           return STATE_WARNING
#       else
#           do_nothing/wait
#
#   if Status == Failed
#       delete_job
#       return STATE_CRITICAL
#
#   if Status == Killed
#       if job_created < 1h
#           do_nothing/wait
#       else
#           reschedule_job
#       return STATE_OK
#
#   if Status == JobNotFound
#       delete_file in $TMP_PATH
#       return STATE_OK
        
## List of job statuses
# ---------------------
# Received      Job is received by the DIRAC WMS
# Checking      Job is being checked for sanity by the DIRAC WMS
# Waiting       Job is entered into the Task Queue and is waiting to picked up for execution
# Running       Job is running
# Stalled       Job has not shown any sign of life since 2 hours while in the Running state
# Completed     Job finished execution of the user application, but some pending operations remain
# Done          Job is fully finished
# Failed        Job is finished unsuccessfully
# Killed        Job received KILL signal from the user
# Deleted       Job is marked for deletion 

# Nagios exit status codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4
STATUS_ALL=('OK' 'WARNING' 'CRITICAL' 'UNKNOWN' 'DEPENDENT')
EXIT_CODE=$STATE_OK
OUTPUT="" 
NB_JOBS=0
NB_JOBS_OK=0
NB_JOBS_WARNING=0
NB_JOBS_CRITICAL=0

# Custom values
TXT="FG_Monitoring_Simple_Job"
TMP_PATH=/tmp/dirac-jobs
JDL=/tmp/$TXT.jdl
JOB_OUT=/tmp
LOGFILE=/tmp/dirac_logs
TIME_START=$(date +%s)

# unset LD_LIBRARY_PATH as it cause awk/sed to fail
unset LD_LIBRARY_PATH

## Functions

log() {
    if $DEBUG; then
        echo -e "$(date '+%Y-%M-%d %H:%M:%S %Z') $@" >> $LOGFILE
    fi
}

output() {
    local TXT="$1"
    OUTPUT+="$(date '+%Y-%M-%d %H:%M:%S %Z') $TXT\n"
}

log_output() {
    local TXT="$1"
    log "$TXT"
    output "$TXT"
}

perf_compute() {
    local JOB_STATUS=$1
    ((NB_JOBS++))
    if [ "$JOB_STATUS" = "$STATE_OK" ]; then
        ((NB_JOBS_OK++))
    elif [ "$JOB_STATUS" = "$STATE_WARNING" ]; then
        ((NB_JOBS_WARNING++))
    elif [ "$JOB_STATUS" = "$STATE_CRITICAL" ]; then
        ((NB_JOBS_CRITICAL++))
    fi
}

perf_output() {
    local STATUS=${STATUS_ALL[$1]}
    TIME_NOW=$(date +%s)
    EXEC_TIME=$(( $TIME_NOW - $TIME_START ))
    local OUT_PERF="$STATUS|exec_time=$EXEC_TIME;;;; nb_jobs=$NB_JOBS;;;; nb_jobs_ok=$NB_JOBS_OK;;;; nb_jobs_ko=$NB_JOBS_CRITICAL;;;; nb_jobs_warn=$NB_JOBS_WARNING;;;;"
    echo "$STATUS"
    echo -e "$OUTPUT"
    log "$OUT_PERF"
    echo "$OUT_PERF"
    exit $1
}

usage () {
    log "Displaying usage"
    echo "Usage: $0 [OPTION] ..."
    echo "Check some workflows on DIRAC"
    echo "Create a job and check its status"
    echo "Create a job, delete it, and check its status"
    echo ""
    echo "  -h|--help     Print this help message"
    echo "  -v|--version  Print probe version"
    echo "  -s|--submit   Submit test jobs"
    echo "  -c|--check    Check jobs statuses"
    echo ""
}

version() {
    log "Displaying version ($PROBE_VERSION)"
    echo "$0 version $PROBE_VERSION"
}

check_env() {
    local PROXY_INFO=""
    local TIME_LEFT=0

    log_output "Checking environment and proxy..."

    if [ -z "$DIRAC" ]; then
        log_output "DIRAC environment not set !"
        log_output "Please source DIRAC's bashrc !"
        perf_output $STATE_CRITICAL
    fi

    if ! PROXY_INFO=$(dirac-proxy-info -v | awk '/timeleft/ { print $3 }') ; then
        log_output "Proxy is not valid !"
        log_output "Did you initialise it with 'dirac-proxy-init -g biomed_user' ?"
        perf_output $STATE_CRITICAL
    else
        TIME_LEFT=$(echo $PROXY_INFO | awk -F ":" '{ print $1 }')
        if [ "$TIME_LEFT" -lt "24" ]; then
            log_output "CRITICAL : Proxy is valid for less than a day !!!"
            output "Tip : 'dirac-proxy-init -g biomed_user -v 720:00'"
            EXIT_CODE=$STATE_CRITICAL
        elif [ "$TIME_LEFT" -lt "168" ]; then
            log_output "WARNING : Proxy is valid for less than a week !!!"
            output "Tip : 'dirac-proxy-init -g biomed_user -v 720:00'"
            EXIT_CODE=$STATE_WARNING
        else
            log_output "INFO : Proxy is valid for $TIME_LEFT h ($(($TIME_LEFT / 24)) d)"
            EXIT_CODE=$STATE_OK
        fi
    fi

    if [ ! -d $TMP_PATH ]; then
        log "TMP_PATH Not found !"
        log "Creating TMP_PATH in $TMP_PATH..."
        mkdir -p $TMP_PATH
    fi

    log "Creating JDL at $JDL"
    cat <<EOF > $JDL
JobName       = "$TXT";
Executable    = "/bin/echo";
Arguments     = "$TXT";
StdOutput     = "StdOut";
StdError      = "StdErr";
OutputSandbox = {"StdOut","StdErr"};
EOF
}

check_exit_code() {
    local EXIT_CODE=$1
    log "Exit code is $EXIT_CODE"
    # TODO Check exit code
}

submit_job() {
    local OUT=$TMP_PATH/`date +%s`
    log "Submitting job in $OUT"
    dirac-wms-job-submit -f $OUT $JDL >> /dev/null
    check_exit_code $?
    log "JobId submitted is `cat $OUT`"
    echo `cat $OUT`
}

delete_job() {
    local ID=$1
    log "Deleting job $ID"
    sleep 1
    log "$(dirac-wms-job-delete $ID)"
    check_exit_code $?
}

kill_job() {
    local ID=$1
    log "Killing job $ID"
    log "$(dirac-wms-job-kill $ID)"
    check_exit_code $?
}

reschedule_job() {
    local ID=$1
    log "Rescheduling job $ID"
    log "$(dirac-wms-job-reschedule $ID)"
    check_exit_code $?
}

check_output() {
    local ID=$1
    log "Checking output of job $ID"
    log "$(dirac-wms-job-get-output -D $JOB_OUT $ID)"
    check_exit_code $?
    
    if [ "$(cat $JOB_OUT/$ID/StdOut)" = "$TXT" ]; then
        echo $STATE_OK
    else
        echo $STATE_CRITICAL
    fi
}

clean_job() {
    local ID=$1
    local FILE=$2
    log "Cleaning job $ID"
    if [ -f $JOB_OUT/$ID/StdOut ]; then
        rm $JOB_OUT/$ID/*
        rmdir $JOB_OUT/$ID
    fi
    if [ -f $FILE ]; then
        rm $FILE
    fi
}

check_time() {
    local ID=$1
    local FILE=$2
    local TIME_WINDOW=$(($3-1))
    local SUB_TIME=$(basename $FILE)
    local NOW=$(date +%s)
    local DELTA=$(( $NOW - $SUB_TIME - 1 ))

    log "Checking if job was created less than $(date +%-H --date=@$TIME_WINDOW)h ago"
    log "Time difference is $DELTA s"

    if [ $DELTA -lt "$TIME_WINDOW" ]; then
        log "Seems good, waiting..."
        echo $STATE_OK "Waiting"
    else
        log "Seems too long... WARNING !"
        echo $STATE_WARNING "Taking too long time !"
    fi
}

check_status() {
    local ID=$1
    local FILE=$2
    local RCODE=$STATE_UNKNOWN
    local ACTION="Not defined yet"
    local TMP="$RCODE $ACTION"

    log "Checking status of job $ID"
    local STATUS=$(dirac-wms-job-status "$ID")
    check_exit_code $?

    STATUS=$(echo $STATUS | awk '{print $2}')
    if [ "$STATUS" = "" ]; then
        log_output "Status=NotFound; (Assuming already cleaned)"
    else
        log_output "$STATUS"
    fi


    if [ "$STATUS" = "Status=Received;" ]; then
        TMP="$(check_time $ID $FILE 3600)"

    elif [ "$STATUS" = "Status=Checking;" ]; then
        TMP=$(check_time $ID $FILE 3600)

    elif [ "$STATUS" = "Status=Waiting;" ]; then
        TMP=$(check_time $ID $FILE 7200)

    elif [ "$STATUS" = "Status=Running;" ]; then
        TMP=$(check_time $ID $FILE 7200)

    elif [ "$STATUS" = "Status=Stalled;" ]; then
        TMP=$(check_time $ID $FILE 7200)
        RCODE=$(echo $TMP | awk '{print $1}')
        ACTION=$(echo $TMP | awk '{print $2}')
        if [ "$RCODE" -gt "0" ]; then
            delete_job $ID
            ACTION="Deleting job"
        fi
        TMP="DONOTPARSE"

    elif [ "$STATUS" = "Status=Completed;" ]; then
        TMP=$(check_time $ID $FILE 7200)

    elif [ "$STATUS" = "Status=Done;" ]; then
        RCODE=`check_output $ID`
        delete_job $ID
        ACTION="Deleting job"
        TMP="DONOTPARSE"

    elif [ "$STATUS" = "Status=Failed;" ]; then
        delete_job $ID
        RCODE="$STATE_CRITICAL"
        ACTION="Deleting job"
        TMP="DONOTPARSE"

    elif [ "$STATUS" = "Status=Killed;" ]; then
        TMP=$(check_time $ID $FILE 3600)
        RCODE=$(echo $TMP | awk '{print $1}')
        ACTION=$(echo $TMP | awk '{print $2}')
        if [ "$RCODE" -gt "0" ]; then
            reschedule_job $ID
            ACTION="Rescheduling job"
        fi
        RCODE=$STATE_OK
        TMP="DONOTPARSE"

    elif [ "$STATUS" = "Status=Deleted;" ]; then
        TMP=$(check_time $ID $FILE 3600)

    elif [ "$STATUS" = "" ]; then
        clean_job $ID $FILE
        RCODE=$STATE_OK
        ACTION="Cleaning"
        STATUS="Status=NotFound;"
        TMP="DONOTPARSE"
    fi

    if [ "$TMP" != "DONOTPARSE" ]; then
        RCODE=$(echo $TMP | awk '{print $1}')
        ACTION=$(echo $TMP | awk '{print $2}')
    fi

    echo "$RCODE" "$STATUS" "$ACTION"
    
}

## Go for it !

start_jobs() {
    log_output "------------- New submission starting --------------"
    check_env
    log_output "Submitting some jobs..."
    log_output "---"
    log_output "Normal JobID : $(submit_job)"
    sleep 2
    local TOBEDELETED=$(submit_job)
    log_output "---"
    log_output "JobID to be deleted : $TOBEDELETED"
    delete_job $TOBEDELETED
    log_output "----------------------------------------------------"
}

check_jobs() {
    log_output "--------------- New check starting -----------------"
    check_env
    log_output "Checking jobs from files (if any)..."
    local FILES=$(find $TMP_PATH -type f)
    if [ ${#FILES[@]} -gt 0 ]; then
        for FILE in $FILES; do
            local ID=$(cat $FILE)
            log_output "---"
            log_output "Found JobID $ID from file $FILE"
            local TMP="$(check_status $ID $FILE)"
            local RCODE=$(echo $TMP | awk '{print $1}')
            local STATUS=$(echo $TMP | awk '{print $2}')
            local ACTION=$(echo $TMP | awk '{print $3}')
            log "tmp: $TMP / rcode: $RCODE / action: $ACTION"
            perf_compute $RCODE
            log_output "JobID $ID : $STATUS / Action=$ACTION; (${STATUS_ALL[$1]})"
            if [ "$RCODE" -gt "$EXIT_CODE" ]; then
                EXIT_CODE=$RCODE
            fi
        done
    else
        log_output "No job found to ckeck."
        EXIT_CODE=$STATE_OK
    fi
    log_output "----------------------------------------------------"
}

## Parse arguments                                                           


# No argument given
if [ $# -eq 0 ] ; then
    usage
fi

# Validate options
if ! OPTIONS=$(getopt -o chsv -l check,help,submit,version -- "$@") ; then
    usage
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) 
            usage
            perf_output $STATE_OK
            ;;
        -v|--version)
            version
            perf_output $STATE_OK
            ;;
        -s|--submit)
            start_jobs
            perf_output $EXIT_CODE
            ;;
        -c|--check) 
            check_jobs
            perf_output $EXIT_CODE
            ;;
        *)
            echo "Incorrect input : $1"
            usage
            perf_output $STATE_CRITICAL
            ;;
    esac
done

#EOF
