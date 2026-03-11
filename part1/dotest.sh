#!/bin/bash
set -ex

logdir=~/temp
logfile=${logdir}/rlog
mkdir -p "${logdir}"

go test -v -race -run "$@" 2>&1 | tee "${logfile}"

go run ../tools/raft-testlog-viz/main.go < "${logfile}"
