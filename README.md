# beabee Helm chart

One release per tenant (`beabee-<id>` — release name, namespace and derived
resource names are all conventions, see `templates/_helpers.tpl`). Deployed
by Flux from `main`; bump `version` in `Chart.yaml` for any change to roll
out (`update.sh` does this for app releases). Tenant configuration lives in
each tenant's HelmRelease values plus the SOPS secret `env-<release>`.

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

**Provisioning does not change how anyone logs in.** The app keeps its
built-in password login until `BEABEE_LOGIN_PROVIDER=oidc` is set (below).

The instance-admin PAT the reconciler delivers must belong to a service user
with `IAM_OWNER` on the virtual instance: the app uses it for user
management now, and later `backend-cli idp setup` will write login settings,
an Actions target and the label policy with it.

### Handing the credentials to the app

The app has two independent switches (monorepo `docs/oidc-login.md`):
`BEABEE_IDP_PROVIDER` selects the identity provider it manages accounts in,
`BEABEE_LOGIN_PROVIDER` selects how people log in. Their settings live under
`BEABEE_IDP_SETTINGS_*` and `BEABEE_LOGIN_SETTINGS_*`. Wire the settings
from the provisioned Secrets with the chart's existing `secretRefs`
mechanism; the two `*_PROVIDER` switches go in the tenant's env secret:

```yaml
secretRefs:
  # IdP: account provisioning/linking against the tenant's instance — the
  # PAT is instance-scoped, it cannot touch other tenants. The virtual
  # instance's API is its issuer URL.
  BEABEE_IDP_SETTINGS_URL: { name: zitadel-<release>, key: ISSUER }
  BEABEE_IDP_SETTINGS_PAT: { name: zitadel-instance-pat-<release>, key: pat }

  # Login: OIDC against the tenant's instance (only read once
  # BEABEE_LOGIN_PROVIDER=oidc)
  BEABEE_LOGIN_SETTINGS_ISSUER: { name: zitadel-<release>, key: ISSUER }
  BEABEE_LOGIN_SETTINGS_CLIENTID: { name: zitadel-<release>, key: CLIENT_ID }
  # optional — the app default is the same `openid profile email`
  BEABEE_LOGIN_SETTINGS_SCOPES: { name: zitadel-<release>, key: OIDC_SCOPES }
```

Leave `BEABEE_LOGIN_SETTINGS_CLIENTSECRET` unset: the Job creates a public
PKCE client, and an empty secret means "public client" to the app. The
redirect URI defaults from `BEABEE_AUDIENCE` and matches
`zitadel.redirectPaths` / `zitadel.postLogoutPaths`. There is no
organisation to pin — accounts land in the instance's default organisation.
Two more settings arrive with later monorepo PRs and are not needed yet:
`BEABEE_LOGIN_SETTINGS_ACCOUNTURL` (the Zitadel console security page,
`https://<login-domain>/ui/console/users/me?id=security`) and
`BEABEE_IDP_SETTINGS_WEBHOOKSECRET` (signing key of the email-verified
Actions target).

#### Instance states

A tenant is in exactly one of three states, and moves through them in this
order:

| State          | `BEABEE_LOGIN_PROVIDER`             | `BEABEE_IDP_PROVIDER`                                  |
| -------------- | ----------------------------------- | ------------------------------------------------------ |
| Standalone     | `local` (default)                   | `none` (default)                                       |
| IdP Transition | `local`                             | `zitadel` + `BEABEE_IDP_SETTINGS_URL` / `_PAT`         |
| OIDC           | `oidc` + `BEABEE_LOGIN_SETTINGS_*`  | `zitadel`                                              |

- `zitadel.enabled: true` alone leaves the tenant **Standalone** — the
  instance exists, nothing about login changes.
- **IdP Transition**: set `BEABEE_IDP_PROVIDER=zitadel` plus the two
  `BEABEE_IDP_SETTINGS_*` refs. Password login stays on; existing contacts
  are provisioned/linked in the instance (`backend-cli user provision` /
  `user link`). Safe to combine with enabling provisioning.
- **OIDC** — the login flip — is `BEABEE_LOGIN_PROVIDER=oidc`, not the
  presence of an issuer. Set it only once the contacts are linked. The app
  refuses to boot with `BEABEE_LOGIN_PROVIDER=oidc` and
  `BEABEE_IDP_PROVIDER=none`.
- **Break-glass**: set `BEABEE_LOGIN_PROVIDER=local` and redeploy. Local
  password hashes are kept, so password login works again immediately.

> **Version gate:** these variables only exist in app images that contain
> monorepo #696/#699/#700 (requires app image ≥ `<version including #700>`).
> On such an image, `BEABEE_IDP_PROVIDER=zitadel` without
> `BEABEE_IDP_SETTINGS_URL` / `_PAT` fails at boot; on older images all of
> these variables are ignored and the tenant stays on password login.

### Offboarding

Deliberately nothing is deleted automatically (same policy as the CNPG
`Database`): on uninstall the login-domain Ingress goes away, but the
virtual instance (with its users), the `zitadel-<release>` and
`zitadel-instance-pat-<release>` Secrets and their sources in the zitadel
namespace stay. Removing them is a manual step: delete the instance via the
System API (this removes its domains with it) and delete the Secrets.
A tenant migrating to self-hosted first gets an export
(`/admin/v1/export`, `withPasswords: true` — users incl. password hashes).
