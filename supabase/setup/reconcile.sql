-- Create parkshare_project_url and parkshare_job_secret in Supabase Vault first.
-- The latter must match JOB_SECRET in the Edge Function environment.
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.schedule(
  'parkshare-reconcile',
  '* * * * *',
  $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets
            where name = 'parkshare_project_url') || '/functions/v1/market',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-job-secret', (select decrypted_secret from vault.decrypted_secrets
                       where name = 'parkshare_job_secret')
    ),
    body := '{"action":"sweep"}'::jsonb,
    timeout_milliseconds := 30000
  );
  $job$
);
