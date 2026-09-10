# beabee Helm chart

One release per tenant (`beabee-<id>` — release name, namespace and derived
resource names are all conventions, see `templates/_helpers.tpl`). Deployed
by Flux from `main`; bump `version` in `Chart.yaml` for any change to roll
out (`update.sh` does this for app releases). Tenant configuration lives in
each tenant's HelmRelease values plus the SOPS secret `env-<release>`.

## Running backend CLI commands (`cli.*`)

The Kubernetes replacement for `docker compose exec api_app yarn backend-cli
...`. `kubectl exec` into the api-app pod does not work here: backend-cli
boots a full beabee application rather than talking to the API, so inside
api-app's cgroup two copies of the app compete for one memory limit and the
command (or the pod) gets OOM-killed. Instead the chart renders a
**suspended CronJob `<release>-cli`** — it never fires, it is only a template
with the tenant's image tag, env (the same as the backends and the migration
Job: env secret, `secretRefs`, `zitadel.state` env) and its own resources
(`cli.resources`, default 512Mi request / 1Gi limit). Stamp a Job from it
with your command. `kubectl create job --from=cronjob/... -- <cmd>` alone is
refused by kubectl ("cannot specify --from and command"), so render the Job
client-side, set the command, and create it:

```sh
NS=beabee-<id>
kubectl -n $NS create job cli-$(date +%s) --from=cronjob/$NS-cli --dry-run=client -o json \
  | jq '.spec.template.spec.containers[0].command = ["yarn","backend-cli","user","list"]' \
  | kubectl -n $NS create -f -
kubectl -n $NS logs -f job/cli-<ts>
```

The array is exactly what you typed after `docker compose exec api_app`
before. The operator runbook (hive-kubernetes-prod `docs/support.md`) is the
place for a wrapper around this; the chart only ships the template.

**Interactive commands** (`setup admin`, `setup support-email`,
`setup payment-methods`, `user delete` without `-y`) prompt on a TTY and
would hang in a Job. Start a throwaway pod from the same template and exec
into it — the old `exec` workflow, in a pod with the CLI's own limit:

```sh
kubectl -n $NS create job cli-shell --from=cronjob/$NS-cli --dry-run=client -o json \
  | jq '.spec.template.spec.containers[0].command = ["sleep","3600"]' \
  | kubectl -n $NS create -f -
kubectl -n $NS exec -it job/cli-shell -- bash
node@cli-shell-...:/opt/apps/backend$ yarn backend-cli setup admin
kubectl -n $NS delete job cli-shell
```

Notes:

- Job names must be unique in the namespace, hence the timestamp. Pods carry
  `component=cli` for Loki. `backoffLimit` is 0: a failing command is not
  retried, the Job shows `Failed` and its pod is kept for `kubectl logs` /
  `describe`. Finished Jobs are deleted after `cli.ttlSecondsAfterFinished`
  (default one day).
- Runs use the tenant's deployed image (`image.tag` / `appVersion`), so the
  CLI always matches the running backends. The command replaces the image's
  `tini` entrypoint, which is fine for a one-shot process.
- Unmodified (plain `kubectl create job --from`), the template runs
  `yarn backend-cli --help`: a smoke test of image and env.
- `cli.enabled: false` removes the template (nothing else depends on it).

## Invoices schema (`invoices.*`)

Hive's invoicing reads every tenant database through one internal role
(`invoices.role`, a CNPG managed role on the shared cluster). What
hive-deploy-stack's `new-instance.sh` used to set up by hand in psql, a
post-install/upgrade hook Job now does on every deploy: an `invoices` schema
with the `payment_seen` table the invoicing writes to, `USAGE` on both
schemas, `SELECT` on the app's tables (existing and, via default privileges,
future ones).

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
- an idempotent post-hook Job then provisions the inside of the instance —
  **project** and **OIDC client** (public client + PKCE, redirect URIs on
  `hive.domain`) — and writes Secret **`zitadel-<release>`** with the
  results: `ISSUER`, `INSTANCE_ID`, `PROJECT_ID`, `CLIENT_ID`,
  `OIDC_SCOPES`. On re-runs it also keeps the client's redirect and
  post-logout URIs in sync with `hive.domain`. On first install the Job
  simply waits until the reconciler has delivered the credential (up to
  ~15 min).
- the same Job ensures a **human admin user** (username `admin`,
  `IAM_OWNER` on the instance, email `zitadel.adminEmail` — default
  `admin@<login-domain>`, created as verified so no mail is sent) and
  writes its credentials to Secret **`zitadel-<release>-admin`**
  (`username`, `password`, `email`, `console`). The PAT's machine user
  cannot use the Console; this one can:

  ```sh
  kubectl get secret zitadel-<release>-admin -n <ns> -o jsonpath='{.data.password}' | base64 -d
  ```

  Log in at `https://<login-domain>/ui/console`. The password is not
  forced to change on first login: the Secret is the shared credential for
  devs and support staff, so **do not change the password in the Console**
  — the Secret would not follow. The Secret is **create-once**; the Job
  never updates it. To rotate: delete the Secret and redeploy. The next
  run resets the user's password (even if someone changed it in the
  Console in the meantime) and recreates the Secret. If the user was
  deleted in ZITADEL instead, the next run recreates it with the password
  already in the Secret.

**Provisioning does not change how anyone logs in.** The app keeps its
built-in password login until `BEABEE_LOGIN_PROVIDER=oidc` is set (below).

The instance-admin PAT the reconciler delivers must belong to a service user
with `IAM_OWNER` on the virtual instance: the app uses it for user
management now, and later `backend-cli idp setup` will write login settings,
an Actions target and the label policy with it.

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
   contacts in the instance (`backend-cli user provision` / `user link`).
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
  the provisioned `OIDC_SCOPES` (`openid profile email`). The redirect and
  post-logout URIs default from `BEABEE_AUDIENCE` and match
  `zitadel.redirectPaths` / `zitadel.postLogoutPaths`. There is no
  organisation to pin — accounts land in the instance's default one.
- The app refuses to boot with `BEABEE_LOGIN_PROVIDER=oidc` and
  `BEABEE_IDP_PROVIDER=none`; the `oidc` state always renders both.
- Two more settings arrive with later monorepo PRs and will be added to the
  `oidc` state then: `BEABEE_LOGIN_SETTINGS_ACCOUNTURL` (the Zitadel console
  security page, `https://<login-domain>/ui/console/users/me?id=security`)
  and `BEABEE_IDP_SETTINGS_WEBHOOKSECRET` (signing key of the email-verified
  Actions target).

> **Version gate:** these variables only exist in app images that contain
> monorepo #696/#699/#700 (requires app image ≥ `<version including #700>`).
> On such an image, `BEABEE_IDP_PROVIDER=zitadel` without
> `BEABEE_IDP_SETTINGS_URL` / `_PAT` fails at boot (the chart always renders
> them together); on older images all of these variables are ignored and
> the tenant stays on password login.

### Offboarding

Deliberately nothing is deleted automatically: on uninstall the login-domain
Ingress goes away, but the
virtual instance (with its users), the `zitadel-<release>`,
`zitadel-<release>-admin` and `zitadel-instance-pat-<release>` Secrets and
their sources in the zitadel namespace stay. Removing them is a manual
step: delete the instance via the System API (this removes its domains with
it) and delete the Secrets.
A tenant migrating to self-hosted first gets an export
(`/admin/v1/export`, `withPasswords: true` — users incl. password hashes).
