#!/usr/bin/env bash

echo "TEST: EXIT 0 PRIOR TO wait -n @${SECONDS}"
{ sleep 1; echo "child finishing @${SECONDS}"; exit 1; } &
pid=$!
echo "child proc $pid @${SECONDS}"

sleep 2
wait -n $pid
echo "wait -n $pid return code $? @${SECONDS}"