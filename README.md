# secrets-manager-chart

This repository contains the Helm chart that installs Infisical in the cluster.

## Purpose

The chart wraps the upstream `infisical-standalone` Helm chart `1.10.0` as a dependency.
We use the upstream chart only through values. We never fork or patch its templates.

The wrapper owns these resources:

- An optional `InfisicalStaticSecret` that syncs the SMTP Secret from Infisical (`smtp.enabled`).
- An optional Traefik IngressRoute (`ingressRoute.enabled`).

Infisical's Deployment, Service and ServiceAccount come from the upstream chart.
The upstream Ingress, bundled PostgreSQL and Bitnami Redis are off. The database is CNPG.
The wrapper installs our custom Redis chart as a separate dependency, pinned to
`0.1.0-feature-devsecops-190-087d631-8eb3efb-5` from
`oci://ghcr.io/raulstechtips/charts`.

## Redis dependency

The default is standalone Redis at `infisical-redis:6379`, with persistence,
`noeviction`, one Longhorn storage replica, and internal-CA TLS. Infisical uses
`rediss://` and trusts only the CA certificate mounted from `infisical-redis-tls`
at `/etc/redis-ca/ca.crt` through `NODE_EXTRA_CA_CERTS`. The private TLS key is
not mounted into Infisical.
This connection profile is standalone. Switching to Sentinel also requires
changing Infisical's client settings; changing only `redis.mode` is not sufficient.

Infisical and its Redis dependency use the existing Secret `infisical-redis-admin-credentials-secret`,
key `redis-password`. Make this credential available before Infisical starts:
restore it from your password manager when bootstrapping an empty cluster.
The dependency does not ask Infisical to provision its own startup credential.
Use a URL-safe password, as the existing Kubernetes environment-variable
composition does not percent-encode URI passwords.

The Redis NetworkPolicy explicitly permits Infisical's upstream pod labels
(`component: infisical`, `app: infisical-standalone`) in the same namespace.
Those pods do not have the release-label format used by the Redis chart.

Environment overrides replace `extraEnv`, `extraVolumes`, and `extraVolumeMounts`
lists. Retain the Redis entries from `charts/values.yaml` when adding database,
SMTP or application settings. In particular, replace the old
`redis-infisical-master` endpoint and plaintext Redis URL, and keep the Redis CA
mount alongside the PostgreSQL CA mount. Existing cluster-config values must be
updated before deployment; adding the dependency does not override those lists.

This creates new Redis PVCs. It does not move old queues or data, remove the old
release, or delete its PVCs. Plan the application cutover and required data
transfer before synchronizing Argo CD. Do not remove the old Redis until the
application has been checked against the new instance.

The chart is published to GHCR. Argo CD installs it with values from the `cluster-config` repository (`apps/dev/infisical.yaml`):

```
oci://ghcr.io/raulstechtips/charts/infisical
```

## Before first install

Infisical needs two root keys: `ENCRYPTION_KEY` and `AUTH_SECRET`.
They live in NordPass and in the Secret `infisical-bootstrap`. They never go into git.
The pod reads them through `infisical-standalone.infisical.kubeSecretRef` (envFrom). The chart never creates or changes this Secret.

Create the namespace and the Secret by hand before the first sync:

```sh
kubectl create namespace infisical
kubectl create secret generic infisical-bootstrap -n infisical \
  --from-literal=ENCRYPTION_KEY=<from NordPass> \
  --from-literal=AUTH_SECRET=<from NordPass>
```

For a brand-new Infisical (empty database) there are no keys yet. Generate them once on your workstation and store both in NordPass FIRST, then create the Secret as above:

```sh
openssl rand -hex 16     # ENCRYPTION_KEY
openssl rand -base64 32  # AUTH_SECRET
```

Losing these keys makes every stored secret unrecoverable.

`SITE_URL` is not a chart value. Set it in the cluster-config `extraEnv` list with the other pod env.

## Values reference

Defaults are in `charts/values.yaml`. Environment values go in cluster-config.

| Key | Default | Meaning |
| --- | --- | --- |
| `infisical.authRef.name` | `""` | `InfisicalAuth` used by the SMTP `InfisicalStaticSecret`. Required when `smtp.enabled`. |
| `infisical.authRef.namespace` | `""` | Namespace of that `InfisicalAuth`. Required when `smtp.enabled`. |
| `infisical.projectSlug` | `""` | Infisical project holding the SMTP secrets. Required when `smtp.enabled`. |
| `infisical.environmentSlug` | `""` | Infisical environment holding the SMTP secrets. Required when `smtp.enabled`. |
| `smtp.enabled` | `false` | `true` syncs the SMTP Secret. It doesn't wire env (see SMTP). |
| `smtp.secretName` | `infisical-smtp-secret` | Name of the synced Kubernetes Secret. |
| `smtp.secretPath` | `/infisical/smtp` | Infisical path to read from. |
| `smtp.refreshInterval` | `60s` | How often the operator re-syncs. |
| `smtp.keys` | six `SMTP_*` keys | Map of Secret key to Infisical key. Merges per key. |
| `ingressRoute.enabled` | `false` | `true` renders a Traefik IngressRoute to the Infisical Service. |
| `ingressRoute.host` | `""` | Host to match. Required when enabled. |
| `ingressRoute.tlsSecretName` | `""` | TLS Secret. Required when enabled. |
| `ingressRoute.entryPoints` | `[websecure]` | Traefik entry points. |
| `ingressRoute.ingressClass` | `traefik-external` | Value of the `kubernetes.io/ingress.class` annotation. |
| `ingressRoute.middlewares` | `[]` | List of `{name, namespace}`. |
| `infisical-standalone.infisical.kubeSecretRef` | `infisical-bootstrap` | envFrom Secret with `ENCRYPTION_KEY` and `AUTH_SECRET`. Created by hand (see Before first install). |
| `infisical-standalone.infisical.extraEnv` | Redis TLS connection entries | Pod env. cluster-config supplies the full list (`SITE_URL`, DB, Redis, SMTP). Retain the Redis entries. |
| `infisical-standalone.ingress.enabled` | `false` | Upstream Ingress off. The IngressRoute does routing. |
| `infisical-standalone.ingress.nginx.enabled` | `false` | Upstream ingress-nginx dependency off. |
| `infisical-standalone.postgresql.enabled` | `false` | Bundled PostgreSQL off. |
| `infisical-standalone.redis.enabled` | `false` | Bundled Redis off. |

Any other `infisical-standalone.*` key goes straight to the upstream chart (image, replicas, affinity, resources, volumes).

## Wiring env

Rules that bite:

- `values.yaml` is not templated. `{{ }}` stays a literal string.
- YAML anchors only work within one file. You can't point at an anchor in the chart defaults from cluster-config.
- Lists replace wholesale. cluster-config's `extraEnv` is the full list, including `SITE_URL` and the SMTP refs.
- Maps merge per key. `smtp.keys` is a map, so you can override one key and keep the rest.
- `$(VAR)` only expands variables defined earlier in the same list. Put `DB_USER`, `DB_PASSWORD` and the rest before `DB_CONNECTION_URI`.
- `$(VAR)` composition doesn't percent-encode. A password with `@`, `:`, `/` or `?` breaks the URI. Use URL-safe credentials or the CNPG `uri` key below.

See `apps/dev/infisical.yaml` in `raulstechtips/cluster-config` for the live values.

## SMTP

`smtp.enabled: true` only syncs the Secret `infisical-smtp-secret` through an `InfisicalStaticSecret`.
The pod reads it through the `SMTP_*` entries in `extraEnv`. Those refs are `optional: true`.

So a missing Secret or a missing ref doesn't fail the pod. Email just stops working, with no error at startup.
If mail doesn't go out, check the env names on a running pod:

```sh
kubectl -n infisical get secret infisical-smtp-secret
kubectl -n infisical exec deploy/infisical-infisical-standalone-infisical -- env | grep '^SMTP_' | cut -d= -f1
```

## Changing env

Running pods don't pick up a changed SMTP Secret. A changed `extraEnv` (such as `SITE_URL`) rolls the pods on its own.
Roll them on purpose: bump `infisical-standalone.infisical.podAnnotations.configRevision` in cluster-config and sync.

```yaml
infisical-standalone:
  infisical:
    podAnnotations:
      configRevision: "2"
```

## Argo and releases

The Argo CD Application `infisical` (`cluster-config/argo/dev/infisical.yaml`) has no automated sync. That's on purpose. You sync it by hand.

Each build publishes a chart version. A `main` build looks like `1.0.1-main-<sha7>-<n>`. A branch build looks like `1.0.1-feature-devsecops-44-<sha7>-<n>`.
The chart package `charts/infisical` on GHCR is public, so Argo pulls it without credentials.

On `main`, `argoDeploy` opens a PR in cluster-config that sets `targetRevision` in `argo/dev/infisical.yaml`.
Merge that PR only when you intend to sync it. Merging changes what the next sync installs.

`argocd app diff` exits 1 when there are differences. That isn't a failure.

## Restore on a new cluster

Do these in order. Each step has a check.

There is no CNPG backup of `pg-infisical` today. Without the database, the keys alone bring back an empty Infisical. Backups are a follow-up ticket.

1. Argo CD is installed (public `argocd` chart).
   ```sh
   kubectl -n argocd get deploy argocd-server
   ```
2. The chart package `charts/infisical` is public and pullable.
   ```sh
   helm show chart oci://ghcr.io/raulstechtips/charts/infisical --version <version>
   ```
3. The namespace exists.
   ```sh
   kubectl create namespace infisical
   kubectl get namespace infisical
   ```
4. `github-registry-secret` exists, created by hand from NordPass. It pulls the private `secrets-manager` image. Normally it comes from Infisical, which isn't running yet.
   ```sh
   kubectl -n infisical get secret github-registry-secret
   ```
5. CNPG cluster `pg-prod` runs with database `pg-infisical` and role `infisical-pg-admin`. `pg-infisical-database-credentials-secret` is reflected into `infisical`.
   ```sh
   kubectl -n prod get cluster pg-prod
   kubectl -n infisical get secret pg-infisical-database-credentials-secret
   ```
6. The CA Secret for `verify-ca` exists in `infisical`.
   ```sh
   kubectl -n infisical get secret raulstechtips-internal-ca-key-pair
   ```
7. The Redis password Secret exists before the wrapper starts its dependency.
   ```sh
   kubectl -n infisical get secret infisical-redis-admin-credentials-secret
   ```
8. `infisical-bootstrap` exists, created from NordPass (see Before first install).
   ```sh
   kubectl -n infisical get secret infisical-bootstrap -o jsonpath='{.data}' | grep -c ENCRYPTION_KEY
   ```
9. Sync with `smtp.enabled: false`. Once Infisical is up, install the Infisical operator and `universal-auth-credentials`. Then set `smtp.enabled: true`, sync, and roll the pods (see Changing env).
   ```sh
   kubectl -n infisical rollout status deploy/infisical-infisical-standalone-infisical
   kubectl get infisicalauth infisical-prod-universal-auth -n default
   kubectl -n infisical get infisicalstaticsecret infisical-smtp-secret
   ```

## Upgrades

To upgrade Infisical:

1. Bump the `infisical-standalone` dependency version in `charts/Chart.yaml` and run `helm dependency update charts`.
2. Set the image tag in `cluster-config/apps/dev/infisical.yaml` (`infisical-standalone.infisical.image.tag`).
3. Merge, then sync the Application when you're ready.

The upstream chart also has `infisical.autoBootstrap` and a Secret named `infisical-bootstrap-secret`. That feature bootstraps the first org and admin user.
It has nothing to do with the `infisical-bootstrap` Secret. We don't use it.
