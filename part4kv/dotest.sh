#!/bin/bash
set -ex

outdir=/Users/shentang/temp
mkdir -p "${outdir}"
# 若传入测试名（如 TestClientRequestBeforeConsensus），则输出到 测试名.txt；否则为 rlog
testname="${1:-rlog}"
logfile="${outdir}/${testname}.txt"

go test -v -race -run "$@" 2>&1 | tee "${logfile}"

go run ../tools/raft-testlog-viz/main.go -output "${outdir}" < "${logfile}"
