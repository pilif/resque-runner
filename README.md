# resque-runner

resque-runner is a environment-agnostic worker-daemon for running
[resque](https://github.com/defunkt/resque) jobs. Instead of coupling
the task of queue processing with the language of the specific resque
implementation, this daemon will watch for jobs and then shell out to
any script or program of your choice to do the actual work.

## features

* doesn't poll redis but uses [BLPOP](http://redis.io/commands/blpop)
to immediately react to new items in a queue
* supports setting a limit of concurrent jobs per queue
* supports an unlimited amount of queues
* uses no resources aside of one continous connection to redis for
waiting on the queue. For running jobs it uses a minimal amount of
additional resources (the bulk is in your external program resque-
runner launches)

## motivation

Aside of the main implementation of resque, there exist many
additional implementations in various languages and at different
states of implementation.

But overall there is no reason why the language of a resque
implementation should at all be relevant when executing jobs.

So the idea was formed to have a generic worker that waits on various
queues and then *shells out* to an otherwise totally opaque other
program to do the actual dirty work.

By using coffee script / node.js to do the actual work, it was
possible to chose a design that is, in addition to being platform-
agnostic, also superior to many existing solutions out there:

Instead of forking and polling, resque-runner is able to use BLPOP to
block without consuming resources until a work item is posted to a
queue. This way there's no need to consume any memory for worker
processes until there really is work to do.

Conversely, under high load with many smaller jobs, by reacting
immediately to additions to a queue instead of polling, this has the
potential of processing jobs much more quickly.

## usage

Before running the first time, call `npm install` from inside the
installation directory in order to install the dependencies.

Then, call `resque-runner.coffee` with one argument: The path to a
configuration file. The `cfg.json.template` that's included with the
package already lists the defaults which might be fine for you for
most cases.

One thing you need to configure is the program you want resque-runner
to execute when a work item is added to any of the watched queues.

The other thing you might want to configure is the queues you want to
watch: For each queue, add an entry to the "runners" configuration
directive. The key is the queue you want to watch, the value the
maximum amount of jobs you want to execute at the same time.

If a job appears in a queue, resque-runner will execute this script,
pass the name of the queue as the first parameter and the complete job
description in JSON format to STDIN.

If the program exits with a zero exit code, the job is assumed to be
successful.

If the program exits with a non-zero exit code, the job is assumed to
have failed. In that case resque-runner will use STDERR output of the
program to get additional information about the failure:

* if the output generated on STDERR is an arbitrary string,
resque-runner will log the job as failed with an
`UnclassifiedRunnerError` exception and the output of STDERR as the
error description
* if the output generated on STDERR is valid JSON, it will unserialize
that and use the members `exception`, `error` and `backtrace` to log
additional info about the failed job.

## administration

resque-runner writes data to redis the same way the original resque
would, so you should just be using the original resque-web interface
for management.

* Jobs are listed the exact same way as original resque
* Queues work the exact same way as in original resque
* resque-runner generates workers dynamically up to the maximum amount
of concurrent jobs you want to allow.
* Because resque-runner handles queues on its own, all workers (which
it generates dynamically as the need arises) would have the same PID.
To prevent this, resque-runner logs its dynamic workers as
(pid_of_resque-runner)-(job-index), whereas job-index is an
ascending 0-indexed number up to the maximum amount of simultanous
jobs you allow resque-runner to run.
* Once resque-runner has created a worker, that specific worker will
remain in the resque web interface with the state "Waiting". Remember
that *it's not actually waiting* though. All but one worker
don't really exist until they are needed. One single worker is
actually using one connection to redis for BLPOP, but it consumes no
CPU time until an event arrives.

## license

resque-runner ist licensed under the MIT license:

Copyright © 2012 Philip Hofstetter

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

