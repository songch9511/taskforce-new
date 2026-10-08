# Pending beta access grants

Migration `20261102000000_billing_beta_email_grants.sql` was applied to production on 2026-10-08. This is a database-only change; no app update is required.

`public.billing_beta_email_grants` is an operator-managed allowlist for approved beta users who have not signed up yet. Store lowercase, trimmed email addresses using a privileged database session; never expose this table to app clients or commit real email addresses. Adding a row does not send an invitation or create an Auth account.

On Auth signup or email confirmation/change, the trigger grants `billing_accounts.legacy_beta = true` only when `auth.users.email_confirmed_at` is present and the current email matches the allowlist. Existing subscription, trial and notice fields are preserved. Accounts undergoing deletion are skipped. Normal beta AI budget safeguards still apply.

When granting access, insert the approved email and backfill any already-confirmed matching user in the same transaction to cover an account that signed up before the allowlist row existed:

```sql
begin;
insert into public.billing_beta_email_grants(email)
values ('approved-beta@example.com') on conflict do nothing;
insert into public.billing_accounts(user_id, legacy_beta)
select id, true from auth.users
where lower(btrim(email)) = 'approved-beta@example.com'
  and email_confirmed_at is not null
on conflict (user_id) do update set legacy_beta = true
where not public.billing_accounts.deleting;
commit;
```

Verify the allowlist row, Auth confirmation state, and corresponding billing entitlement after the transaction. For a pending user, confirm entitlement after their first login with that email. Removing an allowlist row prevents future automatic grants; it does not revoke an already granted account entitlement.
