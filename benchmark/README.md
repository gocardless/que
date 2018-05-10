# Benchmarking

![Que Dashboard](https://raw.githubusercontent.com/gocardless/que/master/benchmark/dashboard.png)

This benchmark is designed to be run in a Kubernetes cluster. The aim is to
plugin to an existing Grafana and Prometheus setup by tagging the Que workers
with the following annotations:

```
Prometheus.io/scrape: "true"
Prometheus.io/port: "8080"
```

When Prometheus starts scraping the targets, you can load the `dashboard.json`
into Grafana and view metrics on worker utilisation and lock performance.

## Starting a benchmark

The first step to starting a benchmark is create an image you want to use for
the benchmarking. You can do this by building the `Dockerfile.benchmark` located
at the root of the Que repo.

```shell
$ docker build -t gocardless/que-benchmark -f Dockerfile.benchmark .
$ docker push gocardless/que-benchmark
```

Once pushed, load the Kubernetes resources into your cluster:

```shell
$ kubectl create namespace que-benchmark
$ kubectl --namespace que-benchmark apply -f benchmark/deployment.yaml
deployment "que-postgres" configured
configmap "que-postgres-init-scripts" configured
service "que-postgres" configured
deployment "que-benchmark" configured
```

Once all pods are ready, you should be able to see them using kubectl:

```
$ kubectl --namespace que-benchmark get pods
NAME                             READY     STATUS    RESTARTS   AGE
que-benchmark-79c779b6db-2mk9q   1/1       Running   0          43m
que-benchmark-79c779b6db-ntqv9   1/1       Running   0          43m
que-benchmark-79c779b6db-r8gkt   1/1       Running   0          43m
que-benchmark-79c779b6db-z7jm4   1/1       Running   0          43m
que-postgres-5c5d69949d-rjpl6    1/1       Running   0          4h
```


select queue, count(*) from que_jobs group by 1;

You can now exec into one of the que containers to kickoff a benchmark:

```
$ kubectl --namespace que-benchmark exec -i que-benchmark-79c779b6db-2mk9q bash
root@que-benchmark-79c779b6db-2mk9q:/que/benchmark# bundle exec seed-jobs 10_000 0 1..10
{"ts":"2018-04-27T20:26:28.611+00:00","level":"INFO","msg":"Truncating que_jobs table"}
{"ts":"2018-04-27T20:26:28.643+00:00","level":"INFO","msg":"Seeding database","now":"2018-04-27T20:26:28.611+00:00","no_of_jobs":10000,"duration_range":[0],"priority_range":[1,2,3,4,5,6,7,8,9,10]}
{"ts":"2018-04-27T20:26:34.254+00:00","level":"INFO","msg":"Finished seeding database","jobs_in_table":10000}
```

This creates 10k jobs, all of which will sleep for 0s, randomly assigned a
priority between 1 and 10. The `run_at` of these jobs will be randomly jittered
over a second to ensure the job IDs don't happen to coincide with the natural
priority of the jobs- if you don't do this, your benchmarks may be misleading.

Now checking the Grafana dashboard should give the information you need to debug
which parts of the worker are bottlenecks.

## Utilisation

The worker utilisation is displayed on the dashboard separated into four
components: time spent working jobs, acquiring locks, unlocking advisory locks
and sleeping.

This accounts for the vast amount of the work done by a Que worker, with the
exception of the Que database Adapter, which at high jobs/s begins to consume
approximately 10% of worker time trying to cast data types.

## Stack tracing

If you want to dig deeper to understand what each worker is doing under load,
then you can install `ruby-prof` and use that to instrument the work loop. If
you choose to do this, we advise trapping SIGQUIT in the bin/que script and
having it trigger a RubyProf.start, then print the results to STDOUT after a few
seconds.

This can be used to produce results like the following:

```
  %total   %self      total       self       wait      child            calls     name
--------------------------------------------------------------------------------
                      1.996      0.001      0.000      1.996          313/314     Que::Worker#work_loop
  99.94%   0.03%      1.997      0.001      0.000      1.997              314     Que::Worker#work
                      1.996      0.000      0.000      1.996         313/2502     Que::Adapters::ActiveRecord#checkout
--------------------------------------------------------------------------------
                      0.099      0.003      0.000      0.095        1251/1252     Que::Adapters::Base#execute
   4.93%   0.17%      0.099      0.003      0.000      0.095             1252     Que::Adapters::Base#cast_result
   ...
```

That can help determine specific causes of slowdown.
