# beabee Helm chart

One release per tenant (`beabee-<id>` — release name, namespace and derived
resource names are all conventions, see `templates/_helpers.tpl`). Deployed
by Flux from `main`; bump `version` in `Chart.yaml` for any change to roll
out (`update.sh` does this for app releases). Tenant configuration lives in
each tenant's HelmRelease values plus the SOPS secret `env-<release>`. A
change to that secret rolls the Deployments through the cluster's Reloader
(`secret.reloader.stakater.com/reload`), since the pods read it only at start.

## Backend CLI template (`cli.*`)

backend-cli boots a full beabee application, so running it with `kubectl exec`
in the api-app pod puts two copies of the app under one memory limit and gets
the command or the pod OOM-killed. The chart therefore renders a **suspended
CronJob `<release>-cli`** that never fires. It is a template for one-off Jobs,
with the tenant's image tag, the same env as the backends and the migration
Job (env secret, `secretRefs`, `zitadel.state` env) and its own resources
(`cli.resources`, default 512Mi request / 1Gi limit). hive-tenants'
`scripts/backend-cli` stamps Jobs from it; it relies on the name
`<release>-cli` and on the app being the first container.

- Pods carry `component=cli` for Loki.
- `backoffLimit` is 0: a failing command is not retried, the Job shows
  `Failed` and its pod is kept for `kubectl logs` / `describe`. Finished Jobs
  are deleted after `cli.ttlSecondsAfterFinished` (default one day).
- Runs use the tenant's deployed image (`image.tag` / `appVersion`), so the
  CLI always matches the running backends. A Job's command replaces the
  image's `tini` entrypoint, which is fine for a one-shot process.
- Unmodified (`kubectl create job --from=cronjob/<release>-cli`), the template
  runs `yarn backend-cli --help`: a smoke test of image and env.
- `cli.enabled: false` removes the template; nothing else in the chart
  depends on it.

## Support access (`supportAccess.*`)

A RoleBinding grants the `beabee-support` ClusterRole (defined in
hive-kubernetes) in the tenant namespace to every ServiceAccount in the
cluster's `beabee-support` namespace, one per person who looks after the
tenants. On by default; `supportAccess.enabled: false` leaves a tenant out.
The role and the subject are fixed in the template, so tenant values cannot
widen them.

## Invoices schema (`invoices.*`)

Hive's invoicing reads every tenant database through one internal role
(`invoices.role`, a CNPG managed role on the shared cluster). A
post-install/upgrade hook Job sets up its access on every deploy: an
`invoices` schema with the `payment_seen` table the invoicing writes to,
`USAGE` on both schemas, `SELECT` on the app's tables (existing and, via
default privileges, future ones).

It runs **as the tenant role**, connecting with the same `BEABEE_DATABASE_URL`
the backends use — no superuser. The tenant role owns the database, so
creating the schema, granting on its own objects and setting default
privileges for objects it creates are all within its rights; the invoicing
role only has to exist. That is also why it is a post- hook: the migration
hook has just created the tables it grants on. An `invoices` schema owned by
another role is left untouched; only the grants on `public` are applied.

The Job uses `postgresClientImage` rather than the app image because the
latter has no `psql`; the default is the cluster's own Postgres image, already
present on the nodes. `invoices.enabled: false` removes the hook.

## ZITADEL instance provisioning (`zitadel.*`, opt-in)

Each client gets their own **virtual instance** in the shared ZITADEL
deployment — their own users, OIDC client, login branding, login domains
and email sender, isolated from other clients, analogous to the per-tenant
database in the shared `hive-pg` cluster (and provisioned the same way: the
chart declares, controllers converge).

`zitadel.enabled: true` provisions on every install/upgrade:

- an Ingress in the ZITADEL namespace **declares the tenant**: its vanity
  login domain (default `auth.<hive.domain>`; override
  `zitadel.loginDomain`) plus annotations naming the virtual instance. The
  central reconciler there creates the **instance**, registers the domains,
  and delivers the instance-admin credential as Secret
  **`zitadel-instance-pat-<release>`** into this namespace. The only manual
  step is the DNS record for the login domain.
- a second Ingress on the login domain, backed by an ExternalName alias of
  the tenant's router, maps `/ui/v2/login/_beabee/*` to the router with the
  prefix stripped. The hosted login is served through a proxy that injects
  a stylesheet at that path, and the app serves it and the login background
  from there (monorepo ADR-0006).
- an idempotent post-hook Job then provisions the inside of the instance —
  **project** and **OIDC client** (public client + PKCE, the app's callback
  on `hive.domain` as redirect URI) — and writes Secret
  **`zitadel-<release>`** with the results: `ISSUER`, `INSTANCE_ID`,
  `PROJECT_ID`, `CLIENT_ID`, `OIDC_SCOPES`. On first install the Job
  simply waits until the reconciler has delivered the credential (up to
  ~15 min).
- once `zitadel.state` is `idp` or `oidc`, a second post-hook Job runs
  `backend-cli setup integrations idp` with the app's env after every
  deploy, which applies the IdP-side settings the app owns (monorepo
  `docs/oidc-login.md`).
- the bootstrap Job also ensures a **human admin user** (username `admin`,
  `IAM_OWNER` on the instance, email `zitadel.adminEmail`, default
  `admin@<login-domain>`, created as verified so no mail is sent) and
  writes its credentials to Secret **`zitadel-<release>-admin`**
  (`username`, `password`, `email`, `console`). The PAT's machine user
  cannot use the Console; this one can. The Secret is the shared credential
  for devs and support staff, so the password is not forced to change on
  first login. The Secret is **create-once**: the Job never updates it, and
  a password changed in the Console leaves it stale. When the Secret is
  missing, the next run resets the user's password and recreates the
  Secret; when the user is missing, the next run recreates it with the
  password already in the Secret.

**Provisioning does not change how anyone logs in.** The app keeps its
built-in password login until `BEABEE_LOGIN_PROVIDER=oidc` is set (below).

The instance-admin PAT the reconciler delivers must belong to a service user
with `IAM_OWNER` on the virtual instance: the app uses it for user
management, and the setup Job writes instance-level settings with it.

### Handing the credentials to the app: `zitadel.state`

The app has two independent switches (monorepo `docs/oidc-login.md`):
`BEABEE_IDP_PROVIDER` selects the identity provider it manages accounts in,
`BEABEE_LOGIN_PROVIDER` selects how people log in. Together they put a
tenant in exactly one of three states. The chart renders the matching env
into every backend and the migration Job from the provisioned Secrets —
you only set `zitadel.state`:

| `zitadel.state`       | State          | Env rendered by the chart                                                                                |
| --------------------- | -------------- | -------------------------------------------------------------------------------------------------------- |
| `standalone` (default) | Standalone     | nothing — password login, instance unused                                                                 |
| `idp`                 | IdP Transition | `BEABEE_IDP_PROVIDER=zitadel`, `BEABEE_IDP_SETTINGS_URL` (← `ISSUER`), `BEABEE_IDP_SETTINGS_PAT` (← `pat`) |
| `oidc`                | OIDC           | the above + `BEABEE_LOGIN_PROVIDER=oidc`, `BEABEE_LOGIN_SETTINGS_ISSUER` (← `ISSUER`), `_CLIENTID` (← `CLIENT_ID`) |

Move one step at a time, **one deploy each**, in this order:

1. `zitadel.enabled: true` — the instance is provisioned, login unchanged.
   Never combine this with a state change: the env references Secrets that
   only exist after the reconciler and the bootstrap Job have run, and pods
   cannot start until they do.
2. `state: idp` — password login stays on; provision/link the existing
   contacts in the instance (`backend-cli user provision`).
3. `state: oidc` — **the login flip.** Only once the contacts are linked.

Break-glass: set `state: idp` and redeploy; local password hashes are kept,
so password login works again immediately.

Notes:

- These env entries are explicit `env`, so they override any `*_PROVIDER`
  or `*_SETTINGS_*` left in the tenant's `env-<release>` secret or in
  `secretRefs`. Tenants on an external IdP keep `zitadel.enabled: false`
  and wire `secretRefs` by hand.
- `BEABEE_LOGIN_SETTINGS_CLIENTSECRET` stays unset: the client is public
  with PKCE, and an empty secret means "public client" to the app.
  `BEABEE_LOGIN_SETTINGS_SCOPES` stays unset too — the app default equals
  the provisioned `OIDC_SCOPES` (`openid profile email`). The client's
  redirect and post-logout URIs are fixed by the app under `BEABEE_AUDIENCE`
  and kept in line by the setup Job. There is no organisation to pin —
  accounts land in the instance's default one.
- The app refuses to boot with `BEABEE_LOGIN_PROVIDER=oidc` and
  `BEABEE_IDP_PROVIDER=none`; the `oidc` state always renders both.
> **Version gate:** these variables exist in app images ≥ `v0.52.0`.
> On such an image, `BEABEE_IDP_PROVIDER=zitadel` without
> `BEABEE_IDP_SETTINGS_URL` / `_PAT` fails at boot (the chart always renders
> them together); on older images all of these variables are ignored and
> the tenant stays on password login.

### Uninstalling

Uninstalling deletes nothing in ZITADEL. Only the login-domain Ingress goes
away; the virtual instance with its users, the `zitadel-<release>`,
`zitadel-<release>-admin` and `zitadel-instance-pat-<release>` Secrets and
their sources in the zitadel namespace stay. Offboarding and exporting a
tenant are in hive-tenants' support guide.
