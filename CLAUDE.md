# Claude instructions

This repository is public. Its only supported consumer is our private
Kubernetes infrastructure repository, which is often used for
cross-referencing during work here and which contains the list of our
clients.

Never mention client names, tenant names, hostnames, namespaces, or any
other identifier taken from the private repository in anything written into
this repository: commit messages, PR titles and descriptions, code comments,
README or values.yaml text, or template names.

Describe the motivating case generically instead. Write "a tenant with a
foreign-owned table in its schema", not the tenant's name. If the generic
description would be too vague to justify the change, the detail belongs in
the private repository, not here.

## Chart version

Bump the patch of `version` in Chart.yaml in every change that alters what
the chart renders: templates, values.yaml defaults, or appVersion. Flux
redeploys a HelmRelease only when the chart version changes, so a change
without a bump merges but never reaches a cluster. Changes that only touch
this file, the README or update.sh need no bump. `update.sh` bumps the
version itself when it sets appVersion.
