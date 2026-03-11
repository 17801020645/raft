#!/bin/bash
set -ex

outdir=/Users/shentang/temp
mkdir -p "${outdir}"
logfile=${outdir}/rlog

go test -v -race -run "$@" 2>&1 | tee "${logfile}"

go run ../tools/raft-testlog-viz/main.go -output "${outdir}" < "${logfile}"
