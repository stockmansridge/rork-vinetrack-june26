# VineTrack Auth Email + Resend SMTP Runbook

Project: `tbafuqwruefgkbyxrxyb` (`https://tbafuqwruefgkbyxrxyb.supabase.co`)

This runbook covers switching Supabase **Auth** emails (password recovery,
signup confirmation, email change) to Resend custom SMTP, with a recorded
rollback path. Application emails (invitations, support, notifications) are a
separate system — they go through the Edge Functions and the shared Resend
module in `supabase/functions/_shared/email/` and are NOT affected by anything
in this document.

Everything here is driven by the GitHub Actions workflow
**`.github/workflows/auth-email-config.yml`** (Actions → *Auth Email Config —
VineTrack* → Run workflow), which uses the repo's existing
`SUPABASE_ACCESS_TOKEN` secret. No secrets are ever printed.

---

## 1. What the mobile apps and portal expect (verified from code)

| Client | Recovery request | Recovery completion |
|---|---|---|
| iOS | `resetPasswordForEmail(email, redirectTo: nil)` (`ios/VineTrack/Backend/Auth/SupabaseAuthRepository.swift`) | Six-digit code → `verifyOTP(type: .recovery)` → `updatePassword` |
| Android | `POST /auth/v1/recover` with email only (`android-vinetrack/.../data/auth/AuthRepository.kt`) | Six-digit code → `POST /auth/v1/verify` (`type: "recovery"`) → `PUT /auth/v1/user` |
| Lovable portal | `resetPasswordForEmail(email, { redirectTo: origin + "/reset-password" })` | Recovery link → `exchangeCodeForSession` → `updateUser({ password })`, with manual six-digit fallback via `verifyOtp` |

Consequences:

- The recovery template **must keep `{{ .Token }}`** (mobile six-digit code)
  **and `{{ .ConfirmationURL }}`** (portal link). Both are present in
  `supabase/auth-templates/recovery.html`; the workflow refuses to apply a
  template missing either variable.
- Mobile does not need a deep link — neither app passes a redirect, and iOS's
  `handlePasswordRecoveryURL` is an unused extra, not a requirement.
- The portal requires its routes in the redirect allowlist (section 3).

## 2. Audit — run first

Run the workflow with action **`audit`**. The job summary reports (read-only):

- Site URL, redirect URL allowlist
- Email sign-in enabled, signup autoconfirm, secure email change
- OTP expiry/length, emails-per-hour rate limit
- Current SMTP status (built-in Supabase service vs custom host), sender
  name/email
- Whether each template (recovery, confirmation, email change, magic link) is
  the Supabase default or custom, and each subject line

A redacted full snapshot (`auth-config-snapshot.json`) is uploaded as a run
artifact with 90-day retention. **This is the rollback record** — every
subsequent action re-captures it before changing anything, so the
pre-change sender, rate limits, and template contents are always preserved.
Passwords and key-like values are redacted in both the summary and the
artifact.

## 3. Apply templates + redirect allowlist

Run action **`apply-templates`**. It sets:

| Email | Subject | Template file |
|---|---|---|
| Password recovery | Reset your VineTrack password | `supabase/auth-templates/recovery.html` |
| Signup confirmation | Confirm your VineTrack account | `supabase/auth-templates/confirmation.html` |
| Email change | Confirm your new VineTrack email address | `supabase/auth-templates/email-change.html` |

It also merges these portal routes into the redirect allowlist (never removes
existing entries):

- `https://portal.vinetrack.com.au/reset-password`
- `https://portal.vinetrack.com.au/auth/callback`

If the portal also runs on a Lovable preview/staging domain, add that origin's
`/reset-password` and `/auth/callback` to the allowlist manually in the
dashboard (Authentication → URL Configuration) — do not add wildcard domains.

This action does **not** change SMTP, so the templates can be reviewed by
sending a recovery email through the existing (built-in) sender first.

## 4. Enable Resend custom SMTP

Prerequisites, in order:

1. `audit` has been run and its artifact saved (rollback record).
2. `apply-templates` has been run (the default Supabase recovery template has
   no six-digit-code guidance, so switching SMTP first would be pointless).
3. The Resend domain **vinetrack.com.au** shows *Verified* in the Resend
   dashboard (Domains), so `notifications@vinetrack.com.au` may send.
4. Repo secret **`RESEND_API_KEY`** exists (Settings → Secrets and variables →
   Actions). This is the same key used by the Edge Functions' Supabase secret,
   but it must also be added as a GitHub secret for this workflow.

Then run action **`enable-smtp`**. Configuration applied:

- Host `smtp.resend.com`, port `465` (TLS), username `resend`
- Password: the Resend API key (from the GitHub secret; never printed)
- Sender: `VineTrack <notifications@vinetrack.com.au>` (overridable via the
  workflow inputs)
- Templates, Site URL, OTP settings, and rate limits are not modified by this
  action.

Note: with custom SMTP active, Supabase lifts its built-in send limits; the
project's `rate_limit_email_sent` value (see audit) then governs Auth email
volume. Raise it in the dashboard (Authentication → Rate Limits) only if
recovery emails start getting throttled.

## 5. Post-activation tests — run immediately

**Mobile (iOS and Android)**

1. Request password recovery from the login screen.
2. Email arrives (check Resend dashboard → Emails for the send + message ID).
3. Email contains the six-digit code block.
4. Enter the code in the app → accepted.
5. Set a new password → sign in with it.

**Portal — link flow**

1. Request recovery from the portal login page.
2. Email arrives via Resend; the button opens
   `https://portal.vinetrack.com.au/reset-password`.
3. Code exchanges for a recovery session; set a new password; sign in.

**Portal — six-digit fallback**

1. Request recovery again; enter the six-digit code manually on the portal's
   reset page → accepted.

**Signup confirmation**

1. Register a controlled test account.
2. Confirmation email arrives via Resend; the link confirms the account.
3. Sign in works after confirmation. Remove the test account afterwards
   (Dashboard → Authentication → Users) if appropriate.

Record for the completion report: activation time (in the `enable-smtp` job
summary), each test result, and the Resend message IDs.

## 6. Failure rule + rollback

If **either** mobile or portal recovery fails after enabling custom SMTP:

1. Run the workflow with action **`rollback-smtp`** immediately. This clears
   the custom SMTP settings, reverting Auth email delivery to Supabase's
   built-in service (heavily rate-limited but functional). Templates and the
   allowlist stay in place — they work with either sender.
2. Confirm the previous recovery flow works again (built-in sender).
3. If the failure was template-related, restore the previous template contents
   from the pre-change snapshot artifact
   (`mailer_templates_*_content` fields) via Dashboard → Authentication →
   Email Templates, or fix the file in `supabase/auth-templates/` and re-run
   `apply-templates`.
4. Diagnose before re-enabling: Resend dashboard → Emails (rejections show the
   reason), domain verification status, and the exact error. Do not leave a
   broken password-reset flow enabled.

## 7. Sender addresses at a glance

| System | Sender | Delivery path |
|---|---|---|
| Auth (recovery, signup, email change) | `VineTrack <notifications@vinetrack.com.au>` | Supabase Auth → Resend SMTP |
| Invitations | `VineTrack Invitations <invites@send.vinetrack.com.au>`* | Edge Function → Resend API |
| Support | `VineTrack Support <support@send.vinetrack.com.au>`* | Edge Function → Resend API |

\* Edge Function defaults from `supabase/functions/_shared/email/config.ts`;
overridable with the `EMAIL_FROM_*` Supabase Edge Function secrets. If
`vinetrack.com.au` (root) is the verified Resend domain rather than
`send.vinetrack.com.au`, set `EMAIL_FROM_DEFAULT`, `EMAIL_FROM_INVITES`, and
`EMAIL_FROM_SUPPORT` secrets to root-domain addresses so every email system
sends from the same verified domain.
