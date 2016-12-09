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
#   Main DIRAC probe :
#       Can submit jobs or check jobs workflow
#       Management of dirac's command's timeouts
#       Max script execution time of ~300s (nagios)
#
# Changelog:
# v0.1 2016-12-01 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#       Initial Release
# v0.2 2016-12-07 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#       Add timeout management of dirac's commands
#       Workflow review
# v0.3 2016-12-09 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#       Better timeout management (dirac + overall script)

## Please adapt to your local settings

# path to dirac client
DIRAC_PATH=/usr/lib/dirac

# temporary path (subdirs "dirac-jobs", "dirac-outputs" and "dirac-logs" will
# be created here).
TMP_PATH=/tmp

# activate debug logs ?
DEBUG=true

# where to put the logs
DEBUGFILE=$TMP_PATH/dirac_debug_log

# time allowed for dirac's commands to execute
TIMEOUT="20s"

# Job name / comparison sting (no space)
TXT="FG_Monitoring_Simple_Job"

# These global vars are not defined for this nagios user/session
# (only defined by dirac-proxy-init)
export X509_CERT_DIR=/etc/grid-security/certificates
export X509_USER_CERT=~/.globus/usercert.pem
export X509_USER_KEY=~/.globus/userkey.pem
export X509_USER_PROXY=/tmp/x509up_u500

### Do not edit below this line ### 

PROBE_VERSION="0.3"

## Workflow
# ---------
# * source DIRAC environment (bashrc)
# * each dirac's command is checked against a timeout and its exit_code
#       - if timeout; return STATE_WARNING
# * check_env :
#       check_dirac_environment
#       check_proxy
#           if proxy_is_valid < 7 days
#               return STATE_WARNING
#           if proxy_is_valid < 1 day
#               return STATE_CRITICAL
#       check_or_create $TMP_PATH/{dirac-jobs,dirac-outputs}
#       create_jdl
#
# * Create jobs (every 60 min)
#
#   submit_job:
#       store job_id as a timestamped file in $TMP_PATH/dirac-jobs
#   submit_job:
#       store job_id as a timestamped file in $TMP_PATH/dirac-jobs
#       wait 2s
#       delete the job (job will have status=Killed)
#
# * Check jobs (every 60 min)
#
#   For each job_id in $TMP_PATH/dirac-jobs : check_job_status
#
#   if Status in { Received, Checking, Waiting, Running,
#                  Matched, Completed, Deleted }
#       do_nothing/wait
#       if job_created < 4h
#           return STATE_OK
#       else
#           return STATE_WARNING
#
#   if Status = Done
#       check_job_output
#       if output is expected
#           return STATE_OK
#       else
#           return STATE_CRITICAL
#       delete_job
#
#   if Status = Stalled
#       if job_created < 4h
#           do_nothing/wait
#           return STATE_OK
#       else
#           delete_job
#           return STATE_WARNING
#
#   if Status = Failed
#       delete_job
#       return STATE_CRITICAL
#
#   if Status = Killed
#       if job_created < 1h
#           do_nothing/wait
#       else
#           reschedule_job
#       return STATE_OK
#
#   if Status = JobNotFound
#       clean_job in $TMP_PATH
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
# Matched       ? 

# Nagios exit status codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4
STATUS_ALL=('OK' 'WARNING' 'CRITICAL' 'UNKNOWN' 'DEPENDENT')
EXIT_CODE=$STATE_OK

# Output computing stuff
NB_JOBS=0
NB_JOBS_OK=0
NB_JOBS_WARNING=0
NB_JOBS_CRITICAL=0
TIME_START=$(date +%s)
TXT_START=$(date +%Y%m%d_%H%M%S)

# Get DIRAC environment
source $DIRAC_PATH/bashrc

# unset LD_LIBRARY_PATH as it cause awk/sed to fail
unset LD_LIBRARY_PATH

## Functions

severity() {
    local SEVERITY="$1"
    local TEXT=""

    if [ "$SEVERITY" = "I" ]; then
        TEXT="INFO"
    elif [ "$SEVERITY" = "C" ]; then
        TEXT="CRITICAL"
    elif [ "$SEVERITY" = "W" ]; then
        TEXT="WARNING"
    fi

    echo $TEXT
}

log() {
    local SEVERITY="$1"
    local TEXT="$2"

    if $DEBUG; then
        TEXT="$(severity $SEVERITY) $TEXT"
        echo -e "$(date '+%Y-%M-%d %H:%M:%S %Z') $TEXT" >> $DEBUGFILE
    fi
}

output() {
    local SEVERITY="$1"
    local TEXT="$2"

    TEXT="$(severity $SEVERITY) $TEXT"

    echo "$(date '+%Y-%M-%d %H:%M:%S %Z') $TEXT" >> $JOB_LOGS/$TXT_START.log
}

log_output() {
    local SEVERITY="$1"
    local TEXT="$2"

    log "$SEVERITY" "$TEXT"
    output "$SEVERITY" "$TEXT"
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
 
    if [ "$JOB_STATUS" -gt "$EXIT_CODE" ]; then
        EXIT_CODE=$JOB_STATUS
    fi

    log "I" "nb_jobs=$NB_JOBS; nb_jobs_ok=$NB_JOBS_OK; nb_jobs_crit=$NB_JOBS_CRITICAL; nb_jobs_warn=$NB_JOBS_WARNING;"
}

perf_exit() {
    local STATUS=${STATUS_ALL[$1]}
    TIME_NOW=$(date +%s)
    EXEC_TIME=$(( $TIME_NOW - $TIME_START ))
    local OUT_PERF="$STATUS|exec_time=$EXEC_TIME;;;; nb_jobs=$NB_JOBS;;;; nb_jobs_ok=$NB_JOBS_OK;;;; nb_jobs_ko=$NB_JOBS_CRITICAL;;;; nb_jobs_warn=$NB_JOBS_WARNING;;;;"
    echo "$STATUS"
    cat $JOB_LOGS/$TXT_START.log
    log "I" "$OUT_PERF"
    echo "$OUT_PERF"
    exit $1
}

usage () {
    log "I" "Displaying usage"
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
    log "I" "Displaying version ($PROBE_VERSION)"
    output "I" "$0 version $PROBE_VERSION"
}

check_exit_code() {
    local EXCODE=$1
    local OUT=""

    log "I" "Exit code is $EXCODE"

    if [ "$EXCODE" -eq "124" ]; then
        log_output "W" "There was a timeout ($TIMEOUT) in dirac command"
        EXIT_CODE=$STATE_WARNING
        echo "timeout"
    elif [ "$EXCODE" -eq "0" ]; then
        echo "ok"
    else
        echo "TODO EXIT_CODE = $EXCODE"
    fi

    # TODO Check exit code
}

check_timeout() {
    local COMMAND=$1
    local OUTPUT=""
    local TIMEOUT_STATUS=""

    log_output "I" "Running command : $COMMAND"
    OUTPUT=$(timeout $TIMEOUT $COMMAND)
    TIMEOUT_STATUS=$(check_exit_code $?)

    echo -e "timeout_status $TIMEOUT_STATUS\n$OUTPUT"
}

check_paths() {
    for DPATH in dirac-jobs dirac-outputs dirac-logs; do
        if [ ! -d $TMP_PATH/$DPATH ]; then
            log "W" "$TMP_PATH/$DPATH Not found !"
            log "I" "Creating in $TMP_PATH/$DPATH..."
            mkdir -p $TMP_PATH/$DPATH
        fi
    done

    JOB_LIST=$TMP_PATH/dirac-jobs
    JOB_OUT=$TMP_PATH/dirac-outputs
    JOB_LOGS=$TMP_PATH/dirac-logs
}

check_env() {
    local PROXY_INFO=""
    local TIME_LEFT=0

    log_output "I" "Checking environment and proxy..."

    if [ -z "$DIRAC" ]; then
        log_output "C" "DIRAC environment not set !"
        log_output "C" "Please check probe configuration (DIRAC_PATH ?)"
        perf_exit $STATE_CRITICAL
    fi

    local TMP="$(check_timeout "$DIRACSCRIPTS/dirac-proxy-info -v")"
    TIMEOUT_STATUS=$(echo "$TMP" | awk '/timeout_status/ {print $2}')
    TIME_LEFT=$(echo "$TMP" | awk '/timeleft/ { print $3 }')
    TIME_LEFT=$(echo "$TIME_LEFT" | awk -F ":" '{ print $1 }')

    if ! [ "$TIME_LEFT" -eq "$TIME_LEFT" ] 2>/dev/null; then
        if [ "$TIMEOUT_STATUS" = "timeout" ] && [ -f $X509_USER_PROXY ]; then
            log_output "W" "Try to use the current proxy ($X509_USER_PROXY)"
            EXIT_CODE=$STATE_WARNING
        else
            log_output "C" "Proxy is not valid !"
            log_output "C" "Did you initialise it with 'dirac-proxy-init -g biomed_user' ?"
            perf_exit $STATE_CRITICAL
        fi
    else
        if [ "$TIME_LEFT" -lt "24" ]; then
            log_output "C" "Proxy is valid for less than a day !!!"
            output "C" "Tip : 'dirac-proxy-init -g biomed_user -v 720:00'"
            EXIT_CODE=$STATE_CRITICAL
        elif [ "$TIME_LEFT" -lt "168" ]; then
            log_output "W" "Proxy is valid for less than a week !!!"
            output "W" "Tip : 'dirac-proxy-init -g biomed_user -v 720:00'"
            EXIT_CODE=$STATE_WARNING
        else
            log_output "I" "Proxy is valid for $TIME_LEFT h ($(($TIME_LEFT / 24)) d)"
            EXIT_CODE=$STATE_OK
        fi
    fi

    JDL=$TMP_PATH/$TXT.jdl

    log "I" "Creating JDL at $JDL"
    cat <<EOF > $JDL
JobName       = "$TXT";
Executable    = "/bin/echo";
Arguments     = "$TXT";
StdOutput     = "StdOut";
StdError      = "StdErr";
OutputSandbox = {"StdOut","StdErr"};
EOF
}

submit_job() {
    local OUT=$JOB_LIST/`date +%s`
    local JOB_ID=""
    log "I" "Submitting job in $OUT"
    check_timeout "$DIRACSCRIPTS/dirac-wms-job-submit -f $OUT $JDL" >> /dev/null 2>&1
    JOB_ID=$(cat $OUT)
    if [ "$JOB_ID" -eq "$JOB_ID" ]; then
        log "I" "JobId submitted is $JOB_ID"
    else
        log_output "C" "Cannot submit job !"
        JOB_ID="NONE"
    fi
    echo "$JOB_ID"
}

delete_job() {
    local ID=$1

    log "I" "Deleting job $ID"
    local TMP="$(check_timeout "$DIRACSCRIPTS/dirac-wms-job-delete $ID")"
    local TIMEOUT_STATUS=$(echo "$TMP" | awk '/timeout_status/ {print $2}')

    echo "$TIMEOUT_STATUS"
}

reschedule_job() {
    local ID=$1

    log "I" "Rescheduling job $ID"
    local TMP="$(check_timeout "$DIRACSCRIPTS/dirac-wms-job-reschedule $ID")"
    local TIMEOUT_STATUS=$(echo "$TMP" | awk '/timeout_status/ {print $2}')

    echo "$TIMEOUT_STATUS"
}

clean_job() {
    local ID="$1"
    local FILE="$2"

    log "I" "Cleaning job $ID ($FILE)"

    if [ -d $JOB_OUT/$ID ]; then
        log "I" "Removing $JOB_OUT/$ID/* : $(rm $JOB_OUT/$ID/*)"
        log "I" "Removing $JOB_OUT/$ID/  : $(rmdir $JOB_OUT/$ID)"
    else
        log "I" "Directory $JOB_OUT/$ID not found (so not deleted)..."
    fi
    # TODO 
    # Really check if file exist : if [ -z ${FILE+x} ] && [ -f $FILE ]; then
    if [ -f $FILE ]; then
        log "I" "Removing $FILE $(rm $FILE)"
    else
        log "I" "[ -z ${FILE+x} ] && [ -f $FILE ] : Did not match..."
    fi
}

check_output() {
    local ID=$1
    local RCODE=""

    log "I" "Checking output of job $ID"
    local TMP=$(check_timeout "$DIRACSCRIPTS/dirac-wms-job-get-output -D $JOB_OUT $ID")
    local TIMEOUT_STATUS=$(echo $TMP | awk '/timeout_status/ {print $2}')

    if [ "$TIMEOUT_STATUS" = "timeout" ]; then
        RCODE=$STATE_WARNING
        ACTION="None"
    elif [ "$(cat $JOB_OUT/$ID/StdOut)" = "$TXT" ]; then
        log_output "I" "Output is good !"
        local DTMP=$(delete_job $ID)
        if [ $DTMP = "ok" ]; then
            RCODE=$STATE_OK
            ACTION="Deleting Job"
        else
            RCODE=$STATE_WARNING
            ACTION="None"
        fi
    else
        log_output "C" "Output is bad.."
        RCODE=$STATE_CRITICAL
        local DTMP=$(delete_job $ID)
        if [ $DTMP = "ok" ]; then
            ACTION="Deleting Job"
        else
            ACTION="None"
        fi
    fi

    echo "$RCODE" "$ACTION"
}

check_time() {
    local ID=$1
    local FILE=$2
    local TIME_WINDOW=$(($3-1))
    local SUB_TIME=$(basename $FILE)
    local NOW=$(date +%s)
    local DELTA=$(( $NOW - $SUB_TIME - 1 ))

    log "I" "Checking if job was created less than $(date +%-H --date=@$TIME_WINDOW)h ago"
    log "I" "Time difference is $DELTA s"

    if [ $DELTA -lt "$TIME_WINDOW" ]; then
        log "I" "Seems good, waiting..."
        echo $STATE_OK "Waiting"
    else
        log "W" "Seems too long !"
        echo $STATE_WARNING "Taking too long time !"
    fi
}

check_status() {
    local ID=$1
    local FILE=$2
    local RCODE=$STATE_UNKNOWN
    local ACTION="Not_defined_yet"
    local TMP="$RCODE $ACTION"

    log "I" "Checking status of job $ID"
    local OUTPUT=$(check_timeout "$DIRACSCRIPTS/dirac-wms-job-status $ID")
    local TIMEOUT_STATUS=$(echo $OUTPUT | awk '/timeout_status/ {print $2}')
    local STATUS=$(echo "$OUTPUT" | awk '/Status=/ {print $2}')

    if [ "$STATUS" = "" ]; then
        if [ "$TIMEOUT_STATUS" = "timeout" ]; then
            RCODE=$STATE_WARNING
            ACTION="None"
            STATUS="Status=UnKnown;"
            TMP="DONOTPARSE"
        else
            log_output "I" "Status=NotFound; (Assuming already deleted)"
        fi
    else
        log_output "I" "$STATUS"
    fi

    if [ "$STATUS" = "Status=Received;" ]; then
        TMP=$(check_time $ID $FILE 14400)

    elif [ "$STATUS" = "Status=Checking;" ]; then
        TMP=$(check_time $ID $FILE 14400)

    elif [ "$STATUS" = "Status=Waiting;" ]; then
        TMP=$(check_time $ID $FILE 14400)

    elif [ "$STATUS" = "Status=Running;" ]; then
        TMP=$(check_time $ID $FILE 14400)

    elif [ "$STATUS" = "Status=Matched;" ]; then
        TMP=$(check_time $ID $FILE 14400)

    elif [ "$STATUS" = "Status=Completed;" ]; then
        TMP=$(check_time $ID $FILE 14400)

    elif [ "$STATUS" = "Status=Deleted;" ]; then
        TMP=$(check_time $ID $FILE 14400)

    elif [ "$STATUS" = "Status=Done;" ]; then
        TMP=$(check_output $ID)

    elif [ "$STATUS" = "Status=Stalled;" ]; then
        TMP=$(check_time $ID $FILE 14400)
        RCODE=$(echo $TMP | awk '{print $1}')
        ACTION=$(echo $TMP | awk '{print $2}')
        if [ "$RCODE" -gt "0" ]; then
            local DTMP=$(delete_job $ID)
            if [ $DTMP = "ok" ]; then
                ACTION="Deleting Job"
            else
                ACTION="None"
            fi
        fi
        TMP="DONOTPARSE"

    elif [ "$STATUS" = "Status=Failed;" ]; then
        local DTMP=$(delete_job $ID)
        if [ $DTMP = "ok" ]; then
            ACTION="Deleting Job"
        else
            ACTION="None"
        fi
        RCODE="$STATE_CRITICAL"
        TMP="DONOTPARSE"

    elif [ "$STATUS" = "Status=Killed;" ]; then
        TMP=$(check_time $ID $FILE 3600)
        RCODE=$(echo $TMP | awk '{print $1}')
        ACTION=$(echo $TMP | awk '{print $2}')
        if [ "$RCODE" -gt "0" ]; then
            local RTMP=$(reschedule_job $ID)
            if [ $RTMP = "ok" ]; then
                ACTION="Rescheduling Job"
                RCODE=$STATE_OK
            else
                ACTION="None"
                RCODE=$STATE_WARNING
            fi
        fi
        TMP="DONOTPARSE"

    elif [ "$STATUS" = "" ] && [ "$TIMEOUT_STATUS" != "timeout" ]; then
        clean_job "$ID" "$FILE"
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
    local JOB_ID=""
    check_paths
    log_output "I" "------------- New submission starting --------------"
    check_env
    log_output "I" "Submitting some jobs..."

    log_output "I" "---"
    JOB_ID=$(submit_job)
    if [ "$JOB_ID" -eq "$JOB_ID" ] 2>/dev/null; then
        log_output "I" "Normal JobID : $JOB_ID"
        perf_compute $STATE_OK
        sleep 2
    else
        perf_compute $STATE_CRITICAL
    fi

    log_output "I" "---"
    JOB_ID=$(submit_job)
    if [ "$JOB_ID" -eq "$JOB_ID" ] 2>/dev/null; then
        log_output "I" "JobID to be deleted : $JOB_ID"
        local DTMP=$(delete_job $ID)
        if [ $DTMP = "ok" ]; then
            ACTION="Deleting Job"
            perf_compute $STATE_OK
        else
            ACTION="None"
            perf_compute $STATE_WARNING
        fi
    else
        perf_compute $STATE_CRITICAL
    fi
}

check_jobs() {
    check_paths
    log_output "I" "--------------- New check starting -----------------"
    check_env
    log_output "I" "Checking jobs from files (if any)..."
    local FILES="$(find $JOB_LIST -type f)"
    if [ "$(echo -ne ${FILES} | wc -m)" -gt "0" ]; then
        for FILE in $FILES; do
            local TIME_NOW=$(date +%s)
            local ID=$(cat $FILE)
            if [ "$(( $TIME_NOW - $TIME_START ))" -lt "230" ]; then
                log_output "I" "---"
                log_output "I" "Found JobID $ID from file $FILE"
                local TMP="$(check_status $ID $FILE)"
                local RCODE=$(echo $TMP | awk '{print $1}')
                local STATUS=$(echo $TMP | awk '{print $2}')
                local ACTION=$(echo $TMP | awk '{print $3}')
                perf_compute $RCODE
                log_output "I" "JobID $ID : $STATUS / Action=$ACTION; (${STATUS_ALL[$RCODE]})"
            else
                log_output "W" "The script was lauched almost 4 minutes ago..."
                log_output "W" "Skipping job $ID"
                perf_compute $STATE_WARNING
                log_output "I" "JobID $ID : NotChecked / Action=Skipping; (WARNING)"
            fi
        done
    else
        log_output "I" "No job found to ckeck."
    fi
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
            perf_exit $STATE_OK
            ;;
        -v|--version)
            version
            perf_exit $STATE_OK
            ;;
        -s|--submit)
            start_jobs
            perf_exit $EXIT_CODE
            ;;
        -c|--check) 
            check_jobs
            perf_exit $EXIT_CODE
            ;;
        *)
            echo "Incorrect input : $1"
            usage
            perf_exit $STATE_CRITICAL
            ;;
    esac
done

#EOF
