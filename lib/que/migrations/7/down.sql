BEGIN;

DROP TRIGGER que_job_notify ON que_jobs;
DROP FUNCTION que_job_notify();

COMMIT;
