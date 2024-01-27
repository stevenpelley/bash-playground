#!/usr/bin/env bash

echo Running @${SECONDS}
declare -a pids
t=2
{ sleep $((t+1)); exit 1; } &
pids+=($!)
{ sleep $((t+5)); exit 2; } &
pids+=($!)
{ sleep $((t+5)); exit 3; } &
pids+=($!)
{ sleep $((t+5)); exit 4; } &
pids+=($!)
echo "pids: ${pids[@]}"
jobs

# it appears that killing the process matters.  If it is already waiting while
# killed then "wait -n" will pick it up.  However, if it is killed prior to
# "wait -n" it is missed.
#
# I assume this is some sort of signal issue.  Might be worth posting to bash mailing list.
# in https://lists.gnu.org/archive/html/bug-bash/2019-03/msg00125.html
# I found that what I want _should_ work.  This whole time the problem has been that I've
# been killing the processes with SIGTERM.
#
# somewhat recent bugs that might be related:
# https://lists.gnu.org/archive/html/bug-bash/2023-05/msg00073.html
# https://lists.gnu.org/archive/html/bug-bash/2021-05/msg00073.html
# the Former is quite recent (May 2023, ~8 months ago as of Jan 2024) and so it's possible the build I'm using
# doesn't include it
# it does not, I'm on 5.2.15, released 2022-12-13
# 5.2.21 was released 2023-11-09 and should have that fix.  So..... let's go get that.
#
#
echo "killing ${pids[0]}"
kill "${pids[0]}"

echo Pausing @${SECONDS}
sleep $t

echo Looping @${SECONDS}
for f in 1 2 3 4; do
        wait -n -p pid ${pids[@]} 2> /dev/null
        echo wait return status: $? pid $pid @${SECONDS}
done
echo Finishing @${SECONDS}

jobs
