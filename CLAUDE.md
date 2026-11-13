# Claude instructions

This repository is public. It is consumed by two private repositories, which
are often used for cross-referencing during work here:

- **hive-tenants** deploys one release of this chart per tenant and holds the
  list of our clients, their values, and the support guide and scripts.
- **hive-kubernetes** configures the cluster the tenants run on (Flux,
  Postgres, ZITADEL, support access).

Never mention client names, tenant names, hostnames, namespaces, or any
other identifier taken from those repositories in anything written into this
repository: commit messages, PR titles and descriptions, code comments,
README or values.yaml text, or template names. The repository names
themselves are fine.

Describe the motivating case generically instead. Write "a tenant with a
foreign-owned table in its schema", not the tenant's name. If the generic
description would be too vague to justify the change, the detail belongs in
the private repository, not here.

## What goes in the README

The README is the chart's interface: what each value does, what the chart
renders, and the rules a consumer must follow (such as the `zitadel.state`
order). Procedures built on that, and the scripts that run them, belong in
hive-tenants; link to them by repository name.

## Chart version

Bump the patch of `version` in Chart.yaml in every change that alters what
the chart renders: templates or values.yaml defaults. Flux redeploys a
HelmRelease only when the chart version changes, so a change without a bump
merges but never reaches a cluster. Changes that only touch this file or the
README need no bump. The deployed app version is not part of the chart: it
comes from each tenant's `image.tag` in hive-tenants.
