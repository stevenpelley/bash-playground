#!/usr/bin/env bash

is_trapped=false
handle_term () {
    is_trapped=true
    kill -TERM "${pids[@]}"
}

trap handle_term TERM

(
    sleep infinity || exit 1
) &
pids[0]=$!
(
    sleep infinity || exit 1
) &
pids[1]=$!

# handle a signal race and bail
[[ $is_trapped = true ]] && kill -TERM ${pids[@]}
echo "this pid: $$"

# wait returns 143 (128 + 15) when interrupted for TERM, but appears to also
# return this as the status code if the process waited for was termed.
# how do we distinguish the 2?  Is this simply up to each process/program?
# in other words -- don't ever end with a code > 128?
for pid in ${pids[@]}; do
    for (( ; ; )); do
        wait $pid
        status=$?
        echo "pid ($pid) finished with status ${status}"
        ((status > 128)) && continue
        break
    done
done

#while [[ -n $(jobs -p) ]]; do
#    wait -n -p finished_pid $job_pids
#    status=$?
#    echo "pid (${finished_pid}) finished with status ${status}"
#    if [[ -n $finished_pid ]]; then
#       termed_count=$(($termed_count+1))
#    fi
#done