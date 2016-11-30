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
# v0.1 2016-11-23 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#       Initial Release

PROBE_VERSION="0.1"
DEBUG=true

## Workflow
# ---------
# * check_env : 
#       check_or_create $TMP_PATH
#       check_proxy
#           if proxy_is_valid < 7 days
#               return STATE_WARNING
#           if proxy_is_valid < 1 day
#               return STATE_CRITICAL
#       create_jdl
# * Create jobs (every 15 min)
#   submit_job:
#       store job_id as a timestamped file in $TMP_PATH
#   submit_job:
#       store job_id as a timestamped file in $TMP_PATH
#       wait 30s
#       delete the job
#
# * Check jobs :
# For each job_id in $TMP_PATH, check_job_status
#   if Status in { Received, Checking, Running, Completed }
#       do_nothing/wait
#       return STATE_OK
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
#       if job_is_deleted < 24h
#           return STATE_OK
#       else
#           return STATE_WARNING
#
#   if Status == Waiting
#       if job_created < 2h
#           do_nothing/wait
#           return STATE_OK
#       else
#           return STATE_WARNING
#
#   if Status in { Stalled, Killed }
#       delete_job
#       return STATE_WARNING
#
#   if Status == Failed
#       delete_job
#       return STATE_CRITICAL
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
RCODE=$STATE_OK

# Custom values
TXT="FG_Monitoring_Simple_Job"
TMP_PATH=/tmp/dirac-jobs
JDL=/tmp/$TXT.jdl
JOB_OUT=/tmp
LOGFILE=/tmp/dirac_logs
NAGIOSCMD=/var/spool/nagios/cmd/nagios.cmd
# echo "[${DATE}] PROCESS_SERVICE_CHECK_RESULT;${HOST};org.irods.irods3.Resource-Iput;${IPUT_RETURN_CODE};${IPUT_PLUGIN_OUTPUT}" > $NAGIOSCMD

# unset LD_LIBRARY_PATH as it cause awk/sed to fail
unset LD_LIBRARY_PATH

usage () {
    echo "Usage: $0 [OPTION] ..."
    echo "Check some workflows on DIRAC"
    echo "Create a job and check its status"
    echo "Create a job, delete it, and check its status"
    echo ""
    echo "  -h       Print this help message"
    echo "  -v       Print probe version"
    echo "  -s       Submit test jobs"
    echo "  -c       Check jobs statuses"
    echo ""
    echo "No test was run !|exec_time=0;;;; nb_test=0;;;; nb_tests_ok=0;;;; nb_tests_ko=0;;;; nb_skipped=0;;;;"
    exit $STATE_CRITICAL
}

# No argument given
if [ $# -eq 0 ] ; then
    usage
fi

# Validate options
if ! OPTIONS=$(getopt -o scvh -- "$@") ; then
    usage
fi

## Functions

log() {
    if $DEBUG; then
        echo -e "$(date '+%Y-%M-%d %H:%M:%S %Z') $@" >> $LOGFILE
    fi
}

check_env() {
    local PROXY_INFO=""
    local TIME_LEFT=0

    if [ -z "$DIRAC" ]; then
        echo "DIRAC environment not set !"
        echo "Please source DIRAC's bashrc !"
        exit $STATE_CRITICAL
    fi

    if [ ! -d $TMP_PATH ]; then
        log "TMP_PATH Not found !"
        log "Creating TMP_PATH in $TMP_PATH..."
        mkdir -p $TMP_PATH
    fi

    if ! PROXY_INFO=$(dirac-proxy-info -v | awk '/timeleft/ { print $3 }') ; then
        echo "Proxy is not valid !"
        echo "Did you initialise it with 'dirac-proxy-init -g biomed_user' ?"
        exit $STATE_CRITICAL
    else
        TIME_LEFT=$(echo $PROXY_INFO | awk -F ":" '{ print $1 }')
        if [ "$TIME_LEFT" -lt "24" ]; then
            echo "CRITICAL : Proxy is valid for less than a day !!!"
            RCODE=$STATE_CRITICAL
        elif [ "$TIME_LEFT" -lt "168" ]; then
            echo "WARNING : Proxy is valid for less than a week !!!"
            RCODE=$STATE_WARNING
        fi
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
    sleep 3
    log $(dirac-wms-job-delete $ID)
    check_exit_code $?
}

kill_job() {
    local ID=$1
    log "Killing job $ID"
    log $(dirac-wms-job-kill $ID)
    check_exit_code $?
}

reschedule_job() {

    # TODO

    local ID=$1
    log "Rescheduling job $ID"
    log $(dirac-wms-job-reschedule $ID)
    check_exit_code $?
}

check_output() {
    local ID=$1
    log "Checking output of job $ID"
    log $(dirac-wms-job-get-output -D $JOB_OUT $ID)
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

    log "Checking if job was created less than $(date +%-H --date=@$TIME_WINDOW)h ago"
    log "Time difference is $(( $NOW - $SUB_TIME ))"

    if [ $(( $NOW - $SUB_TIME )) -lt "$TIME_WINDOW" ]; then
        log "Seems good, waiting..."
        echo $STATE_OK
    else
        log "Seems too long... WARNING !"
        echo $STATE_WARNING
    fi
}

check_status() {
    local ID=$1
    local FILE=$2

    log "Checking status of job $ID"
    local STATUS=$(dirac-wms-job-status "$ID")
    check_exit_code $?

    log "STATUS is $STATUS"
    STATUS=$(echo $STATUS | awk '{print $2}')

    if [ "$STATUS" = "Status=Received;" ]; then
        RCODE=$(check_time $ID $FILE 3600)
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Checking;" ]; then
        RCODE=$(check_time $ID $FILE 3600)
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Waiting;" ]; then
        RCODE=$(check_time $ID $FILE 7200)
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Running;" ]; then
        RCODE=$(check_time $ID $FILE 7200)
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Stalled;" ]; then
        RCODE=$(check_time $ID $FILE 7200)
        echo $RCODE
    fi
    
    if [ "$STATUS" = "Status=Completed;" ]; then
        RCODE=$(check_time $ID $FILE 7200)
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Done;" ]; then
        RCODE=`check_output $ID`
        delete_job $ID
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Failed;" ]; then
        delete_job $ID
        echo $STATE_CRITICAL
    fi

    if [ "$STATUS" = "Status=Killed;" ]; then
        RCODE=$(check_time $ID $FILE 7200)
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Deleted;" ]; then
        RCODE=$(check_time $ID $FILE 3600)
        echo $RCODE
    fi

    if [ "$STATUS" = "" ]; then
        clean_job $ID $FILE
        echo $STATE_OK
    fi
}

## Go for it !

start_jobs() {
    log "Checking environment and proxy..."
    check_env
    log "Submitting some jobs..."
    log "Normal JobID : $(submit_job)"
    sleep 2
    local TOBEDELETED=$(submit_job)
    log "JobID to be deleted : $TOBEDELETED"
    delete_job $TOBEDELETED
    log "----------------------------------------------------" 
}

check_jobs() {
    log "Checking environment and proxy..."
    check_env
    local EXIT_CODE=$STATE_OK
    log "Checking jobs from files (if any)..."
    local FILES=$(find $TMP_PATH -type f)
    if [ ${#FILES[@]} -gt 0 ]; then
        for FILE in $FILES; do
            local ID=$(cat $FILE)
            log "Found JobID $ID from file $FILE"
            local RCODE=$(check_status $ID $FILE)
            log "Status Code for JobID $ID : $RCODE"
            if [ "$RCODE" -gt "$EXIT_CODE" ]; then
                EXIT_CODE=$RCODE
            fi
        done
    fi
    log "----------------------------------------------------" 
    exit $EXIT_CODE
}

## Parse arguments                                                           

log "----------------New check starting...---------------" 

while [ $# -gt 0 ]; do
    case "$1" in
        -h) 
            usage
            ;;
        -v)
            echo "Version: $PROBE_VERSION"
            exit $STATE_OK
            ;;
        -s)
            log "             --- Starting jobs ---"
            start_jobs
            shift
            ;;
        -c) 
            log "         --- Checking job statuses ---"
            check_jobs
            shift
            ;;
        *)
            echo "Incorrect input : $1"
            usage
            ;;
    esac
done

#EOF
