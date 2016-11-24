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
#   launch_job:
#       store job_id as a timestamped file in $TMP_PATH
#   launch_job:
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
JDL=/tmp/dirac-jdl-simple.jdl
OUT=/tmp/dirac-job-id
TXT="FG_Monitoring_Simple_Job"
TMP_PATH=/tmp/dirac-jobs/
NAGIOSCMD=/var/spool/nagios/cmd/nagios.cmd

usage () {
    echo "Usage: $0 [OPTION] ..."
    echo "Check some workflows on DIRAC"
    echo "Create a job and check its status"
    echo "Create a job, delete it, and check its status"
    echo ""
    echo "  -h       Print this help message"
    echo "  -v       Print probe version"
    echo ""
    echo "No test was run !|exec_time=0;;;; nb_test=0;;;; nb_tests_ok=0;;;; nb_tests_ko=0;;;; nb_skipped=0;;;;"
    exit $STATE_CRITICAL
}

# No argument given
if [ $# -eq 0 ] ; then
    usage
fi

# Validate options
if ! OPTIONS=$(getopt -o v:h "$@") ; then
    usage
fi

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
        *)
            echo "Incorrect input : $1"
            usage
            ;;
    esac
done

# unset LD_LIBRARY_PATH as it cause awk/sed to fail
unset LD_LIBRARY_PATH

# echo "[${DATE}] PROCESS_SERVICE_CHECK_RESULT;${HOST};org.irods.irods3.Resource-Iput;${IPUT_RETURN_CODE};${IPUT_PLUGIN_OUTPUT}" > $NAGIOSCMD

# Functions

check_init() {
    if [ ! -d $TMP_PATH ]; then
        mkdir -p $TMP_PATH
    fi
}

check_proxy() {
    if ! dirac-proxy-info -v > /dev/null ; then
        echo "Proxy is not valid !"
        exit $STATE_CRITICAL
    else
        echo "Proxy is valid"
    fi
}

make_jdl() {
cat <<EOF > $JDL
JobName       = "$TXT";
Executable    = "/bin/echo";
Arguments     = "$TXT";
StdOutput     = "StdOut";
StdError      = "StdErr";
OutputSandbox = {"StdOut","StdErr"};'
EOF
}

launch_job() {
    dirac-wms-job-submit -f $OUT $JDL
    ID=$(cat $OUT)
}

check_status_done() {
    STATUS=$(dirac-wms-job-status -f $OUT | awk '{print $2}')
    if [ "$STATUS" == "Status=Done;" ]; then
        echo "True"
    else
        echo "$STATUS"
    fi
}

check_output() {
    dirac-wms-job-get-output -D /tmp/ $ID
    if [ "$(cat /tmp/$ID/StdOut)" == "$TXT" ]; then
        dirac-wms-job-delete $ID
        rm /tmp/$ID/ -rf
        rm $JDL $OUT -f
        echo "All Good !"
        exit $STATE_OK
    else
        echo "Too Bad..."
        exit $STATE_CRITICAL
    fi
}

delete_job() {
    dirac-wms-job-kill $ID
}


# Go for it !
check_init
check_proxy
make_jdl
launch_job
DONE="Init..."
while [ "$DONE" != "True" ]; do
    DONE=`check_status_done`
    echo "Not done already : $DONE"
done
check_output
