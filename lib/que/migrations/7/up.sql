BEGIN;

CREATE FUNCTION que_job_notify() RETURNS trigger AS $$
  DECLARE
    payload json;
  BEGIN
    -- Don't bother notifying about jobs that aren't ready to run yet - a
    -- worker polling for them later will pick them up regardless.
    IF NEW.run_at IS NOT NULL AND NEW.run_at > now() THEN
      RETURN null;
    END IF;

    -- There's a size limit to what can be broadcast via LISTEN/NOTIFY, so
    -- rather than throw errors when someone enqueues a big job, just
    -- broadcast the most pertinent information, and let the worker query for
    -- the record after it's taken the lock, exactly as it does when polling.
    SELECT row_to_json(t)
    INTO payload
    FROM (
      SELECT
        NEW.queue    AS queue,
        NEW.priority AS priority,
        NEW.job_id   AS job_id,
        to_char(NEW.run_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS run_at
    ) t;

    -- One channel per queue, so listeners only subscribe to the queues they
    -- actually work.
    PERFORM pg_notify('que_job_available_' || NEW.queue, payload::text);

    RETURN null;
  END
$$
LANGUAGE plpgsql;

-- Allow bulk-enqueue code paths to skip this trigger for performance by
-- running `SET LOCAL que.skip_notify = 'true'` in their transaction.
CREATE TRIGGER que_job_notify
  AFTER INSERT ON que_jobs
  FOR EACH ROW
  WHEN (NOT coalesce(current_setting('que.skip_notify', true), '') = 'true')
  EXECUTE PROCEDURE que_job_notify();

COMMIT;
