#!/usr/bin/env bash
#
# source a file that starts async processes and assigns pids to "pids"

# things to write about:
# - naked wait "clearing" job list and exit code history
# - wait -n not clearing this history (but also not catching every finished job.
# It's time based, not working with a queue of jobs finishing)
# - using wait -p without -n to distinguish exit code meaning job exited due to
# signal vs wait woke up due to signal handler.

# what I want:
# wait -<flag> -p varname <pid>...
# that will return immediately if any of the provided pids is known to have
# terminated, or blocks until the first such pid terminates.
# that is, if any of the processes has already terminated I want it to act like
# wait <pid> and repeatedly return its status and set the -p varname variable.
#
# It is then up to the caller to manage an array of remaining pids to wait for.
# I assume the problem is that bash has limited storage for status codes.
# perhaps it should always be an error if any argument is unknown to bash since
# this should never be the case?  Or maybe set up a system to register a user
# variable to store this information.
#
# I'd also like all the info available in the waitpid posix C call, or even the
# waitid system call: WIFEXITED, WEXITSTATUS, WIFSIGNALED, WCOREDUMP, etc

# next idea: use a combination of trap SIGCHLD and "jobs".
# trap ":" CHLD -- wake up "wait" when any child finishes
# then compare a user-managed array of unfinished/non-awaited pids against the
# output of "jobs -p".  Any job in the list of non-awaited pids and not in "jobs
# -p" has presumably ended, so we may "wait <pid>", it should return
# immediately, and provide us the exit code.
#
# to make this a function it should provide an initial list of pids as well as
# a function name to perform on the first non-zero subcommand exit.  The
# function returns (echos) an associative array of pid->exit status


# another idea:
# build a standalone "better wait" that provides the semantics I want as a
# command utility.  It can be something like "waitpids <pid1> <pid2> ..." and it
# returns a pid and status code for that pid, as well as any error.
#
# this might be hard -- If there's any risk that you might get the status code
# for multiple pids then it needs to return all of them (you can't wait twice at
# a system call level).  And since this process won't itself be the parent of the
# processes we're awaiting it may not be able to wait for them.
#
# this can use ptrace, netlink for PROC_EVENT_EXIT, (probably some similar
# eBPF), kqueue with EVFILT_PROC+NOTE_EXIT on BSD and OSX, or
# https://man7.org/linux/man-pages/man2/pidfd_open.2.html which allows
# getting a pid file descriptor which can be poll()ed/epolled but it appears
# you can't get the status code.  And you aren't guaranteed to see the process
# if anyone else is awaiting it.  You could potentially use this to determine
# that it is done or potentially was done before we even checked, and return
# just a pid, and then allow the parent (shell) to query its status.  That might
# make it a more robust "wait -n"
# another complication -- if this call is bg'ed (necessary to handle traps) then
# we don't immediately have its output.  Need to redirect to /dev/fd3 or similar
# and then read this after awaiting.
# This is starting to look complex.


# write about:
# all of the nuances of bash (and sh) "wait", especially those that aren't as
# clearly documented as I'd like, or where the documentation is scattered (man page,
# posix sh standard, online doc, doc sections wait vs signals)


# things I want:
# -n with previously finished jobs
# "wait" with NOHANG -- return immediately if job still running
# full status -- results of waitpid in addition to exit code (e.g., signal terminated)


# is_trapped will be used to determine if there is a signal after defining
# the handler but prior to starting the processes
is_trapped=false
handle_term () {
    is_trapped=true
    #echo "kill -TERM ${pids[@]}"
    if [ ${#pids[@]} -gt 0 ]; then
        kill -TERM "${pids[@]}"
    fi
}
trap handle_term TERM

# start some processes. Defines $pids array
source multiple_sleeps.sh

# handle a signal race with setting up trap and processes.
# bail if we caught a signal while starting processes
[[ $is_trapped = true ]] && kill -TERM ${pids[@]}

echo "this pid: $$"

declare -A pid_to_status
echo_pid_to_status () {
    echo -n "pid_to_status: {"
    for pid in ${!pid_to_status[@]}; do
        echo -n "$pid:${pid_to_status[$pid]},"
    done
    echo "}"
}

(
    sleep 0.5
    kill $$
)

# "wait -n" to exit quickly if a process fails, as well as to wait for all
# processes to complete (will return 127 as none of the processes exist) without
# resetting our ability to "wait <pid>" to get individual statuses.  "wait"
# (no pids or args) resets this ability.
status=0
until (($status == 127)) ; do
    wait -n -p finished_pid ${pids[@]} 2>/dev/null
    status=$?

    if [ -n $finished_pid ] && [ "$status" != 0 ]; then
        # do whatever we'd like on an error
        :
    fi
    #echo "wait -n: ($finished_pid): $status"
done

for pid in ${pids[@]}; do
    # we wait -p, even without -n, to distinguish between return codes > 128
    # being wait waking up due to a trapped signal vs a process exiting with
    # such a code.
    wait -p finished_pid $pid
    status=$?
    #echo "pid ($pid) finished with status ${status}. finished_pid: ($finished_pid)"
    # wait should no longer block, and thus shouldn't be woken up by signal handler
    if [ -z $finished_pid ] && (( status > 128 )); then
        echo "[wait -p] provided no pid.  Status $status" >&2
        exit 1
    fi
    pid_to_status[$pid]=$status
done

echo_pid_to_status