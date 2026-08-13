# beabee Helm chart

One release per tenant (`beabee-<id>` — release name, namespace and derived
resource names are all conventions, see `templates/_helpers.tpl`). Deployed
by Flux from `main`; bump `version` in `Chart.yaml` for any change to roll
out (`update.sh` does this for app releases). Tenant configuration lives in
each tenant's HelmRelease values plus the SOPS secret `env-<release>`.

## ZITADEL org provisioning (`zitadel.*`, opt-in)

Each client can get their own **organization** in the shared ZITADEL
instance — their own users, OIDC client and login branding, isolated from
other clients, analogous to the per-tenant database in the shared `hive-pg`
cluster (and provisioned the same way: the chart declares, controllers
converge).

`zitadel.enabled: true` provisions on every install/upgrade, via an
idempotent post-hook Job:

- the tenant's ZITADEL **organization**, **project** and **OIDC client**
  (public client + PKCE, redirect URIs on `hive.domain`),
- Secret **`zitadel-<release>`** with the results:
  `ISSUER`, `ORG_ID`, `PROJECT_ID`, `CLIENT_ID`, `OIDC_SCOPES`,
- an Ingress in the ZITADEL namespace declaring the tenant's **vanity login
  domain** (default `auth.<hive.domain>`; override `zitadel.loginDomain`).
  A central reconciler there registers the host inside ZITADEL; the only
  manual step is the DNS record for that host.

**Provisioning does not change how anyone logs in.** The app keeps its
built-in password login until its env is explicitly wired up (below).

### Handing the credentials to the app

The app reads OIDC login config from `BEABEE_OIDC_*` and provisioning
config from `BEABEE_IDP_*`. Wire them from the provisioned Secret with the
chart's existing `secretRefs` mechanism:

```yaml
secretRefs:
  # Step 2 (safe anytime): user provisioning/linking against the org
  BEABEE_IDP_ZITADEL_PAT: { name: iam-admin-pat, key: pat }
  BEABEE_IDP_ZITADEL_ORGID: { name: zitadel-<release>, key: ORG_ID }

  # Step 3 (THE LOGIN FLIP — see warning): OIDC login
  BEABEE_OIDC_ISSUER: { name: zitadel-<release>, key: ISSUER }
  BEABEE_OIDC_CLIENTID: { name: zitadel-<release>, key: CLIENT_ID }
  BEABEE_OIDC_SCOPES: { name: zitadel-<release>, key: OIDC_SCOPES }
```

(plus `BEABEE_IDP_PROVIDER=zitadel` in the tenant's env secret for step 2.
No `BEABEE_OIDC_CLIENTSECRET` — the client is public with PKCE. The
redirect URI defaults from `BEABEE_AUDIENCE` and matches
`zitadel.redirectPaths`.)

> **Warning:** setting `BEABEE_OIDC_ISSUER` immediately switches that
> instance to OIDC login and **disables password login**. Never combine it
> with the change that enables provisioning. Order per tenant:
> 1. `zitadel.enabled: true` — org exists, login unchanged;
> 2. provision/link the existing contacts (`backend-cli user provision` /
>    `user link`, needs the `BEABEE_IDP_*` values);
> 3. only then add the `BEABEE_OIDC_*` refs — and the tenant must run an
>    app image that contains the OIDC login feature.

### Offboarding

Deliberately nothing is deleted automatically (same policy as the CNPG
`Database`): on uninstall the login-domain Ingress goes away, but the
organization (with its users), the `zitadel-<release>` Secret and the
ZITADEL-side domain registrations stay. Removing them is a manual step:
delete the org in the ZITADEL Console, delete the Secret, and deregister
the domain (instance + trusted) via the System/Admin APIs.
