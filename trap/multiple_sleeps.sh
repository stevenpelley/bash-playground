#!/usr/bin/env bash

duration=2
declare -a pids
for (( i=0; i<3; i++ )); do
    sleep $duration &
    pids+=($!)
done