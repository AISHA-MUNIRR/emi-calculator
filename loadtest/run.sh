#!/bin/sh
RATE=$1
SECS=$2
N=$((RATE * SECS))
exec httperf --server emi.local --port 32757 --hog --wsesslog=$N,0,/work/sessions.txt --rate=$RATE --timeout=5 --add-header='Content-Type: application/json\n'
