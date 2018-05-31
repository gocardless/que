## Shutting Down Safely

To ensure safe operation, Que needs to be very careful in how it shuts down. When a Ruby process ends normally, it calls Thread#kill on any threads that are still running - unfortunately, if a thread is in the middle of a transaction when this happens, there is a risk that it will be prematurely commited, resulting in data corruption. See [here](http://blog.headius.com/2008/02/ruby-threadraise-threadkill-timeoutrb.html) and [here](http://coderrr.wordpress.com/2011/05/03/beware-of-threadkill-or-your-activerecord-transactions-are-in-danger-of-being-partially-committed/) for more detail on this.

To prevent this, Que will block a Ruby process from exiting until all jobs it is working have completed normally. Unfortunately, if you have long-running jobs, this may take a very long time (and if something goes wrong with a job's logic, it may never happen). The solution in this case is SIGKILL - luckily, Ruby processes that are killed via SIGKILL will end without using Thread#kill on its running threads. This is safer than exiting normally - when PostgreSQL loses the connection it will simply roll back the open transaction, if any, and unlock the job so it can be retried later by another worker. Be sure to read [Writing Reliable Jobs](https://github.com/chanks/que/blob/master/docs/writing_reliable_jobs.md) for information on how to design your jobs to fail safely.

So, be prepared to use SIGKILL on your Ruby processes if they run for too long. For example, Heroku takes a good approach to this - when Heroku's platform is shutting down a process, it sends SIGTERM, waits ten seconds, then sends SIGKILL if the process still hasn't exited. This is a nice compromise - it will give each of your currently running jobs ten seconds to complete, and any jobs that haven't finished by then will be interrupted and retried later.

## SIGKILL and `NoRetry`

If you're using the `NoRetry` strategy from
[`que-failure`](https://github.com/gocardless/que-failure), allowing your
workers to be SIGKILLed can cause jobs that were being worked at the time to
enter an interstitial state where they aren't marked as failed but will not be
picked up by future workers. This is because the strategy marks the job at the
start, when the worker picks it up, and at the end. Because SIGKILL immediately
stops the process, the strategy cannot update the job to indicate failure.

To get around this, Que supports setting a worker timeout, which is an amount of
time that it will wait, after receiving a SIGTERM or SIGINT, for a worker to
stop. If the worker has not stopped within that time, Que will raise a
`QueJobTimeoutError` exception, which will be handled by the `NoRetry` strategy
failure handler and ensure that the job is properly marked as failed.

The timeout can be specified in an argument to the `que` executable, as well as
a message to send with the exception. Run `bin/que --help` for more information.
We recommend setting the timeout to a value slightly less than the time between
SIGTERM and SIGKILL in your environment (e.g. on Heroku, this would be 8-9
seconds).
