#!/usr/bin/env bash

# change to test other signals
sig=TERM

echo "TEST: KILL PRIOR TO wait -n @${SECONDS}"
{ sleep 1; exit 1; } &
pid=$!
echo "kill -$sig $pid @${SECONDS}"
kill -$sig $pid

sleep 2
wait -n $pid
echo "wait -n $pid return code $? @${SECONDS} (BUG)"
wait $pid
echo "wait $pid return code $? @${SECONDS}"

echo "TEST: KILL DURING wait -n @${SECONDS}"
{ sleep 2; exit 1; } &
pid=$!
{ sleep 1; echo "kill -$sig $pid @${SECONDS}"; kill -$sig $pid; } &

wait -n $pid
echo "wait -n $pid return code $? @${SECONDS}"
wait $pid
echo "wait $pid return code $? @${SECONDS}"