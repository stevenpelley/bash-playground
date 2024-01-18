# bash-playground
playing around with bash, specifically to understand signal traps, `wait`, and how to best use bash as a process manager within docker.

I'm new to shell but experienced with other programming languages and linux in general.  It's possible that I'm overlooking superior solutions, but a good amount of googling and searching stack overflow shows a number of other people facing similar challenges with no satisfactory responses.

# Wait
Terminal shells, including POSIX, include a built-in command "wait" to wait for asynchronous (i.e., background) jobs to complete.  Wait additionally returns immediately when signals are trapped/handled.  It is _the_ tool for handling concurrency within shell.  In my limited experience/opinion the semantics of this command are more complex than is necessary, while at the same time failing to precisely handle important use cases.  To top it all off the documentation tends to be scattered as this relates to several topics.

This article attempts to centralize a discussion of wait's behavior, focusing on bash.  I'll consider a specific use case for which I found bash's wait to be insufficient and needlessly complex.

## Use Case
My use case is to create a script as a docker process manager.  I want to start a "main" process in docker, and then additionally start profiling processes within that same container.  There are other ways to accomplish this (don't use a container, don't run the monitoring processes in the same container, monitor in ways that don't require additional processes, etc) so please treat this discussion as interesting for shell scripting rather than as a poor approach for this specific problem.

Specifically, I want to:
- start a main process, storing its PID
- start additional processes, passing the main process PID, e.g., through variable substitution.  Redirect/collect stderr and stdout for each process to files.  This is where shell should be the best tool for the job.
- wait for the first of:
    - the main process to terminate
    - any process to terminate with a non-zero exit code
    - SIGTERM (to the script, as docker process 1)
- on the first of the above conditions it will stop/SIGTERM all remaining processes and then wait for their completion.  Timeouts can be managed by the docker caller.
- return an appropriate exit code.  0 if all processes exit with 0 and no SIGTERM.  143 if SIGTERM and all processes exit with 0 or 143 (143 = 128 + 15 where 15 is the SIGTERM number), other nonzero if any process ends with nonzero -- forward this exit code.

## First attempt

I haven't tested the code in this version, treat as pseudocode

```
# is_trapped will be used to determine if there is a signal after defining
# the handler but prior to starting the processes
is_trapped=false

# set when we kill all remaining processes and intend to exit
exiting=false

# we assume that there is an array $pids containing the pids of all bg processes,
# with the first being our "main" process.
handle_term () {
    is_trapped=true
    exiting=true
    if [ ${#pids[@]} -gt 0 ] && [ $exiting -eq 'false' ]; then
        kill -TERM "${pids[@]}"
    fi
}
trap handle_term TERM

# starts processes asynchronously and creates/populates $pids
# e.g.,
# declare -a pids
# command_1 &
# pids+=($!)
# command_2 &
# pids+=($!)
# command_3 &
# pids+=($!)
source start.sh

# handle a signal race with setting up trap and processes.
# bail if we caught a signal while starting processes
[[ $is_trapped = true ]] && kill -TERM ${pids[@]}

# copy original pids.  We'll unset pids from here as we await them
declare -a awaiting_pids
for idx in ${!pids[@]}; do
    awaiting_pids[$idx]=$pids[$idx]
done

# collect exit codes
declare -A pid_to_code
while ((${#awaiting_pids[@]} > 0)) ; do
    # -n returns on first completed process.  -p stores pid into varname
    # exit status is that of the finished pid, or signal if > 128
    wait -n -p finished_pid ${awaiting_pids[@]} 2>/dev/null
    status=$?

    # finished_pid is defined if wait returned having identified a finished
    # process, rather than returned due to trapped signal
    if [ -n $finished_pid ]; then
        pid_to_code[$finished_pid]=$status
        for idx in ${awaiting_pids[@]}; do
            if [ $finished_pid -eq $awaiting_pids[$idx] ]; then
                unset awaiting_pids[$idx]
                # no break just in case there are duplicates
            fi
        done

        if [ $status -gt 0 ] && [ $exiting -eq 'false' ]; then
            kill -TERM "${pids[@]}"
            exiting=true
        fi
    fi
done

# log or echo pid_to_code if you like.

# prioritize return status codes as (..., 143, 0)
# within this will prioritize by process start order, not termination order
ret_code=0
for code in "${pid_to_code[@]}"; do
    case $code in
        0)
            :
            ;;
        143)
            $ret_code=143
            ;;
        *)
            exit $code
    esac
done

exit $ret_code
```

My first impression is that this code is already far more complex than I expected.  The signal handling code is on its face simple, which is why I chose bash, but the awaiting and status handling code is dense and subtle.

More importantly, this code does not work.  It may miss processes terminating, in which case wait eventually returns 127 as the shell has no unawaited children.  I'll discuss why, some alternatives, and why those alternatives are also imperfect.

## Explanation

### Signals and Trap
Sh and Bash provide "trap" as a command to define signal handlers.  The rules and behavior of sh signals are rather complex.  See https://www.gnu.org/software/bash/manual/html_node/Signals.html and https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html.

Trap runs the provided commands when the designated signal is caught.  Handler commands do not execute until the currently running command finishes.  "wait" is special and will return immediately when a signal is trapped, returning with an exit code for the trapped signal.

The specific signals available, as well as aspects of their behavior, is OS-dependent.  On the whole this gives us what we need to immediately interrupt our script and terminate processes when we receive a SIGTERM signal.

### Wait Variants and options
This is where things get complex.  Wait offers several options.  You can find them at
- https://www.gnu.org/software/bash/manual/html_node/Job-Control-Builtins.html
- `help wait`
- `man bash` (search `/^\s*wait`)
- https://pubs.opengroup.org/onlinepubs/9699919799/utilities/wait.html

Each of these provides subtly different information.  The man page does not mention (in that section) that wait returns immediately on trapped signals.  Only the POSIX/opengroup page admits that wait cannot distinguish between exit codes indicating that the shell process received a signal vs a child process terminated due to the same signal.  I can find no mention of what the shell being "aware of a process" means, and that a call to "wait" without arguments clears all history of child processes and their return codes.

#### POSIX

The most recent POSIX standard requires that wait accept either no arguments or a list of child PIDs.  If no arguments it waits until all child jobs complete before returning, and its exit code will be 0 (or an error if there are no child processes; or a code corresponding to a signal that caused it to return -- 128 + signal number).  If PIDs are provided it will wait until all the associated processes complete and provide an exit code of the process for the last PID (or exit code for signal that woke up wait).  Any PID which is not associated with a still-running child process is treated as a terminated process with exit code 127.  The shell retains exit codes for the {CHILD_MAX} most recently exited child processes.

This is useful.  We can:
- Block until all child jobs complete or we trap a signal
- Block until a specific job completes or we trap a signal; get that job's exit code

But there are several limitations:
- We cannot block until _any_ process terminates.
- We cannot test whether a specific job has terminated without blocking, providing its exit code if it has terminated.  This would first require a query to jobs.
- We cannot easily timeout a call to wait (requires setting up SIGALARM?)
- We cannot distinguish between a child process terminating due to a signal and the call to wait returning due to a trapped signal with the same code.  For example, wait returning with status 143 could indicate that the current script trapped SIGTERM or that the awaited process terminated due to SIGTERM
- Undocumented to the best of my knowledge: calling "wait" without a list of PIDs clears bash's child process return code history.  Any subsequent call to "wait PID" will return 127 and provide an error that the shell is unaware of such a child process.  This prohibits calling "wait" to wait for all children to terminate and then querying their exit codes one by one with "wait PID".  Calling with any list of PIDs does not reset the history of terminated children and return codes.

#### Bash

Bash provides additional options:
- -n: wait until the any process in the list of PIDs terminates.  Note that if a process terminated previously it will be disregarded and will not cause wait to return, thus when two processes terminate at the same time (between our calls to wait -n) we will only be made aware of one of them.
- -p VARNAME: write the associated PID of the finished process to variable with name VARNAME.  The documentation notes that this is only useful alongside the -n option.  However, this appears also useful to distinguish between a signal return code meaning that this shell was interrupted and an awaited process terminated due to signal.  If the shell's wait was interrupted then VARNAME will be empty.
- -f: when job control is enabled wait for the specified PID to terminate, rather than any status change (suspend, resume).

#### Proposed new options

This is _almost_ what I want.  The -n option missing processes when they terminate at the same time seems an oversight.  Note that these options do not reset bash's history of terminated processes.  What I want is for -n to return when any of the provided PIDs processes terminate or to return immediately if the shell is not aware of a child process for a PID.  If the shell is not aware of it then it presumably previously terminated and I can immediately query its exit code using "wait PID".  Here I'd additionally like a no-block option in case of a bug or some misunderstanding so that I won't accidentally block in case the process is still running.

I'd propose new options (And could use better names):
- -s, --strict-any.  Same behavior as -n except that nonfamiliar processes are treated as already-stopped with exit code 127 (just like in "wait PID..."!) and so such PIDs cause wait to return immediately.  This option either conflicts with -n (because it implies it) or requires -n.  When using this it is up to the user to manage the list of PIDs send to wait, removing PIDs from the arguments as you collect their exit codes; or optionally it could manage this for us by requiring an array of pids and then removing from this array the PID that is assigned using -p.
- -n, --nohang.  (nohang taken from wait/waitpid syscalls).  Return immediately with nonzero exit code if any of the provided PIDs are still running.
- -t, --timeout.  Wait timeout, in seconds.  Could use a special return code or assign a variable as in -p on timeout.

### Underlying OS behavior and syscall
See `man wait`.  What I'm asking for above is to more closely match the underlying wait/waitpid syscalls.  The disconnect here is that linux continues to store a terminated processes's exit code until it is awaited by its parent (even if that parent itself terminated and so the new parent is 1 - init).  If it is not awaited the terminated process becomes a zombie process and stays in the process table, it's PID is not recycled.  Bash (or other shell) is this awaiting parent and becomes responsible for providing the same behavior.  It must store a possibly large number of pids/exit codes (hence the {CHILD_MAX} limit).  But this is already a concern for calling "wait PID..." with no options -- bash may no longer store PID and its exit code and is forced to return 127.  A wait -s as described above should still function even if it means missing some exit codes (as they would be missed today without any options).

## Alternatives
The missed processes may be identified by calling `jobs -p` and noticing that additional jobs have terminated.  These could be queries before the next call to `wait -n`.  Note that there will always be a race between a child process terminating and the call to `wait` beginning, at which point a terminated process won't be noticed until the next process terminates/next signal is trapped.

Trapping SIGCHLD.  Requires job control enabled, which isn't ideal for scripts.  I believe this also traps on _any_ subcommand terminating.  One could call `jobs -p` in this handler and compare to a list of awaiting pids.  Any job/pid missing has presumably terminated and may be awaited immediately.

## Crazy Alternatives
Wait is, somewhat necessarily, a shell builtin instead of a command.  Only the parent process may await a child process.  But recent features allow other processes to await the termination (although not the exit code) of non-child processes.  For linux see `man pidfd_open`.  This could allow creating a non-shell utility that accepts a list of PIDs and returns when the first completes or has already completed, as I want with `wait -s` above.  Let's call such a utility `waitn`.  It's exit code would indicate that the job was found and terminated (0), or that a job was not found (1?).  It would write the PID to stdout for use in command substitution.

This would be difficult to work with, especially if you still want to trap signals and interrupt the waiting, which still requires a shell call to the wait builtin.  You'd have to start `waitn` in the background with stdout redirected to a file descriptor (say, 3) and then worry about buffering (shouldn't be a problem if we're only expecting 1 pid?) or else redirect to a temp file and open this temp file as file descriptor 3 before deleting the file.  Then you await `waitn` by PID in a loop to trap any signals.  When `waitn` terminates the call to `wait` provides its exit code and you can read from the file descriptor to get the pid.  At that point you `wait PID` directly to get the status code.  Finally, you update your array/list of awaiting pids to remove this PID.

This is... not better.

## Sane Alternatives
The easiest solution is to give up on some of our goals.  If you can handle not immediately noticing a stopped process then you can either `wait PID...` and accept going back and waiting individual PIDs to get their exit codes later.  You can also simply loop over each PID individually and wait and never wait for multiple processes at once.  These both assume that every process will eventually terminate individually, which is not the case for servers/daemon processes.  This is hard in situations where some process will run indefinitely and you intend to SIGTERM it when some other process ends, all while listening for process termination error exit codes and signals.

In the end I conclude that shell is currently not the best tool for this job if you need precision.

Signal handling is difficult:
- shell handler code may run at any time, interleaved with other script code.  This can make handler/script initialization complex as you deal with the race between starting your "wait" loop and a child process terminating.
- shell handler code is blocked by non-wait statements.  You can't do much else in the same script or you risk blocking handling of a signal.  It's just a "wait wrapper"

But signal handling in other languages is also difficult:
- in C and C++ you cannot allocate memory as malloc may acquire locks and any locking may cause deadlock if running the handler on a thread that already holds the lock.
- Java, short of linking in custom signal handlers, catches SIGINT and SIGTERM and starts its shutdown procedure, which isn't terribly flexible.
- Python almost mimics C.  The signal handler is run in a newly created frame on the main thread.  Raising exceptions in handlers is not safe as they appear "out of thin air" from locations that otherwise should never raise exceptions; it is possible to raise an exception in a "With statement context manager" that will not properly clean up resources.  The Python documentation recommends never raising exceptions from signal handlers in applications that need to be reliable.  You _can_ use multithreading tools to signal other threads, or even the same thread.  The behavior of various library calls in the presence of signals isn't specified -- blocking calls generally do not return on signals.  Pre-asyncio python lacks mechanisms to cancel tasks or block on numerous signals at once, which can make this hard to work with.

I like Go's signal handling.  See below.

Shell Wait semantics have some holes:
- options as described above -- "strict-any" to return immediately if a process previously terminated, "nohang" to return immediately if any process is still running, "timeout" to have wait return after some time without having to set up SIGALARM or similar.
- even with options managing the list of pids to await is complex.  Wait could optionally manage an array variable of PIDs for us, removing the PID that is "returned".

But shell is really convenient.  I omitted the code to set up the child processes here, but this is where full programming languages become cumbersome, especially because those processes may interact, may require arguments resulting from the creation of earlier processes (e.g., passing the PID of the first process to later processes), and the input/output of those processes needs to be managed.  Moving to another language to better handle signals and wait is generally going to make the construction of child processes more verbose and confusing.  See, for example, the insane number of options in Python's subprocess.Popen

For the moment I've settled on Go.  Handled signals simply push an item into a channel (think queue).  You can wait on this channel and on others simultaneously via select.  Await each child process in a separate goroutine (think thread) and have those place an entry in a different channel once wait returns.  At that point it's easy to create a loop to listen for signals or process completion and take the appropriate action.  Go's general code and especially error handling isn't nearly as compact as shell and some other languages, but my example script above shows that this (seemingly simple?) task has already gotten long and complex; Go makes it precise and readable, although certainly not short.  Setting up child processes is easy enough, but I don't see an elegant solution if you want to use this as a library/repeatable tool with generic input applications/processes.  Passing commands to run alongside pipes/redirection/input is the domain of shell.