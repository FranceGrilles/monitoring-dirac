#!/bin/bash

# Nagios exit status codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

# Custom values
JDL=/tmp/dirac-jdl-simple.jdl
OUT=/tmp/dirac-job-id
GROUP=biomed_user
TXT="Monitoring_DIRAC"

# Functions

make_jdl() {
cat <<EOF > $JDL
JobName       = "Simple_Job";
Executable    = "/bin/echo";
Arguments     = "$TXT";
StdOutput     = "StdOut";
StdError      = "StdErr";
OutputSandbox = {"StdOut","StdErr"};'
EOF
}

launch_job() {
dirac-wms-job-submit -f $OUT $JDL
}

check_proxy() {
if ! dirac-proxy-info -v > /dev/null ; then
    echo "Proxy is not valid !"
    exit $STATE_CRITICAL
else
    echo "Proxy is valid"
fi
}

get_status() {
STATUS=$(dirac-wms-job-status -f $OUT | awk '{print $2}')
if [ "$STATUS" == "Status=Done;" ]; then
    echo "True"
else
    echo "$STATUS"
fi
}

check_output() {
    ID=$(cat $OUT)
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

# Go for it !
make_jdl
check_proxy
launch_job
unset LD_LIBRARY_PATH
DONE="Init..."
while [ "$DONE" != "True" ]; do
    DONE=`get_status`
    echo "Not done already : $DONE"
done
check_output
