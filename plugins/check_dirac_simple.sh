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

check_env() {
    echo "Checking env" >> $LOGFILE
    if [ -z "$DIRAC" ]; then
        echo -e "DIRAC environment not set !\nPlease source DIRAC's bashrc !"
        exit $STATE_CRITICAL
    fi

    if [ ! -d $TMP_PATH ]; then
        mkdir -p $TMP_PATH
    fi

    if ! dirac-proxy-info -v > /dev/null ; then
        echo "Proxy is not valid !"
        echo "Did you initialise it with 'dirac-proxy-init -g biomed_user' ?"
        exit $STATE_CRITICAL
    else
        # TODO : check validity time <7d:WARN/ <1d:CRIT
        echo "Proxy is valid"
    fi

    cat <<EOF > $JDL
JobName       = "$TXT";
Executable    = "/bin/echo";
Arguments     = "$TXT";
StdOutput     = "StdOut";
StdError      = "StdErr";
OutputSandbox = {"StdOut","StdErr"};'
EOF
}

check_exit_code() {
    local EXIT_CODE=$1
    echo "Exit code is $EXIT_CODE"  >> $LOGFILE
    #TODO
}

submit_job() {
    local OUT=$TMP_PATH/`date +%s`
    echo "Submitting job in $OUT"  >> $LOGFILE
    dirac-wms-job-submit -f $OUT $JDL >> $LOGFILE
    check_exit_code $?
    echo "JobId submitted is `cat $OUT`"  >> $LOGFILE
    echo `cat $OUT`
}

delete_job() {
    local ID=$1
    echo "Deleting job $ID"  >> $LOGFILE
    sleep 3
    dirac-wms-job-delete $ID >> $LOGFILE
    check_exit_code $?
}

kill_job() {
    local ID=$1
    echo "Killing job $ID"  >> $LOGFILE
    dirac-wms-job-kill $ID >> $LOGFILE
    check_exit_code $?
}

check_output() {
    local ID=$1
    echo "Checking output of job $ID"  >> $LOGFILE
    dirac-wms-job-get-output -D $JOB_OUT $ID >> $LOGFILE
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
    echo "Cleaning job $ID"  >> $LOGFILE
    if [ -f $JOB_OUT/$ID/StdOut ]; then
        rm $JOB_OUT/$ID/*
        rmdir $JOB_OUT/$ID
    fi
    if [ -f $FILE ]; then
        rm $FILE
    fi
}

check_status() {
    local ID=$1
    local FILE=$2
    local RCODE=$STATE_OK

    echo "Checking status of job $ID"  >> $LOGFILE
    local STATUS=$(dirac-wms-job-status "$ID")
    check_exit_code $?

    echo "STATUS is $STATUS"  >> $LOGFILE
    STATUS=$(echo $STATUS | awk '{print $2}')

    echo "$ID $STATUS"  >> $LOGFILE
    if [ "$STATUS" = "Status=Done;" ]; then
        echo "$ID Done"  >> $LOGFILE
        RCODE=`check_output $ID`
        delete_job $ID
        echo $RCODE
    fi

    if [ "$STATUS" = "Status=Deleted;" ]; then
        # TODO : check if job is deleted < 24h : OK / WARN
        echo $STATE_OK
    fi

    if [ "$STATUS" = "Status=Waiting;" ]; then
        # TODO : check if job is created < 2h : OK / WARN
        echo $STATE_OK
    fi

    if [ "$STATUS" = "Status=Failed;" ]; then
        delete_job $ID
        echo $STATE_CRITICAL
    fi

    if [ "$STATUS" = "Status=Received;" ]; then
        echo $STATE_OK
    fi

    if [ "$STATUS" = "Status=Checking;" ]; then
        echo $STATE_OK
    fi

    if [ "$STATUS" = "Status=Running;" ]; then
        echo $STATE_OK
    fi

    if [ "$STATUS" = "Status=Stalled;" ]; then
        echo $STATE_WARN
    fi

    if [ "$STATUS" = "Status=Completed;" ]; then
        echo $STATE_OK
    fi

    if [ "$STATUS" = "Status=Killed;" ]; then
        delete_job $ID
        echo $STATE_WARNING
    fi

    if [ "$STATUS" = "" ]; then
        clean_job $ID $FILE
        echo $STATE_OK
    fi
}

## Go for it !


start_jobs() {
    check_env
    submit_job
    local TOBEDELETED=`submit_job`
    echo "To be deleted : $TOBEDELETED"  >> $LOGFILE
    delete_job $TOBEDELETED
}

check_jobs() {
    local EXIT_CODE=$STATE_OK
    echo "For files...."  >> $LOGFILE
    local FILES=`find $TMP_PATH -type f`
    if [ ${#FILES[@]} -gt 0 ]; then
        for FILE in $FILES; do
            local ID=`cat $FILE`
            echo "JobID from file $FILE : $ID"  >> $LOGFILE
            local RCODE=`check_status $ID $FILE`
            echo "RCODE : $RCODE"  >> $LOGFILE
            if [ "$RCODE" -gt "$EXIT_CODE" ]; then
                EXIT_CODE=$RCODE
            fi
        done
    fi
    exit $EXIT_CODE
}

# Parse arguments                                                           
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
            start_jobs
            shift
            ;;
        -c) 
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
