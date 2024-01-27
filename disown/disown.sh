#!/usr/bin/env bash
#
# test to see if bash reaps disowned processes.
#
# later we can test to see if bash, as process 1 in a container, reaps processes
# that it did not create.

sleep infinity &
pid=$!
disown $pid

sleep infinity

# kill first sleep and see if bash reaps it.
#
# answer: it does