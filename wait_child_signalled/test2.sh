#!/usr/bin/env bash

# showing an example of wait -n that works today but would break if wait -n
# looked in the table of terminated jobs.

# associate array used for consistency with later example
declare -A pids
{ sleep 1; exit 1; } &
pids[$!]=""
{ sleep 2; exit 2; } &
pids[$!]=""
{ sleep 3; exit 3; } &
pids[$!]=""

status=0
while [ $status -ne 127 ]; do
    unset finished_pid
    wait -n -p finished_pid "${!pids[@]}" 2>/dev/null
    status=$?
    if [ -n "$finished_pid" ]; then
        echo "$finished_pid: $status @${SECONDS}"
    fi;
done


unset pids

declare -A pids
{ sleep 1; exit 1; } &
pids[$!]=""
{ sleep 2; exit 2; } &
pids[$!]=""
{ sleep 3; exit 3; } &
pids[$!]=""

status=0
while [ ${#pids[@]} -ne 0 ]; do
    unset finished_pid
    wait -n -p finished_pid "${!pids[@]}"
    status=$?
    if [ -n "$finished_pid" ]; then
        echo "$finished_pid: $status @${SECONDS}"
    fi;
    unset pids[$finished_pid]
done