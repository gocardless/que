CREATE MATERIALIZED VIEW que_jobs_summary
AS (
  select queue, job_class, priority
       , (case when (retryable AND run_at < now()) then 'true' else 'false' end) as due
       , (case when (NOT retryable AND error_count > 0) then 'true' else 'false' end) as failed
       , count(*)
       from que_jobs
   group by 1, 2, 3, 4, 5
);
