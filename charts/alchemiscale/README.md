# `alchemiscale` Helm chart

One chart, instantiated per named deployment in production and per pull request
on the test cluster. It replaces the per-host `docker-compose.yml` stack:

| compose service | chart resource |
| --- | --- |
| `neo4j` | StatefulSet + gp3 PVC, reachable only inside the namespace |
| `alchemiscale-client-API` | `client-api` Deployment + Service (1840) |
| `alchemiscale-compute-API` | `compute-api` Deployment + Service (1841) |
| `alchemiscale-strategist` | `strategist` Deployment |
| `alchemiscale-db-init` | `db-init` Job, a `post-install,post-upgrade` hook |
| Traefik + Let's Encrypt | ALB Ingress with an ACM certificate |
| bind-mounted `./config` | ConfigMap rendered from values |
| hand-copied `.env` | `ExternalSecret` (prod) or a generated Secret (PR) |
| `awslogs` logging driver | Fluent Bit, installed by the cluster module |
| `AWS_ACCESS_KEY_ID`/`SECRET` | EKS Pod Identity on the chart's ServiceAccount |

## usage

```bash
# production
helm upgrade --install omsf charts/alchemiscale -n omsf \
  -f deployments/omsf/values.yaml \
  --set image.tag=2026.08.17-0 --set image.digest=sha256:… --wait

# a PR environment
helm upgrade --install omsf-pr-123 charts/alchemiscale -n omsf-pr-123 --create-namespace \
  -f deployments/omsf/values.yaml -f deployments/omsf/values-pr.yaml \
  --set image.digest=sha256:… --set s3.prefix=pr-123/omsf --wait --atomic

# verify either one
helm test omsf -n omsf --logs
```

Resource names are fixed rather than release-prefixed — one release per
namespace, so `svc/alchemiscale-client-api` means the same everywhere and
scripts can rely on it.

## values worth knowing

| key | does |
| --- | --- |
| `image.repository` / `.tag` / `.digest` | `digest` wins when set: the tag is the label, the digest is what rolls out |
| `deployment` | instance name; drives labels and Secrets Manager paths (`alchemiscale/<deployment>/…`) |
| `domain` | hostnames are `api.<domain>` and `compute.<domain>` |
| `clientApi.*` / `computeApi.*` | replicas, workers, config contents, resources, PDB, topology spread |
| `strategist.enabled` | on by default, including for instances that ship no strategist config; off in PR environments |
| `neo4j.storage` | PVC size; gp3 expands online, so growing later is cheap |
| `neo4j.diskMetrics.enabled` | publishes volume utilisation to CloudWatch for the >80% alarm |
| `secrets.external.enabled` | pull neo4j/JWT material from Secrets Manager via ESO |
| `secrets.generate.enabled` | generate throwaway credentials instead (PR environments) |
| `ingress.enabled` | off for PR environments — nothing on the test cluster is exposed |
| `smokeTest.readOnly` | ping only, for `helm test` against production |

## notes

- **neo4j is never exposed outside its namespace.** Identity administration and
  dumps run in-cluster (`scripts/identity-add.sh`, `scripts/neo4j-dump.sh`).
- **The neo4j pod carries `karpenter.sh/do-not-disrupt: "true"`**, so Auto Mode
  never evicts a database to repack nodes.
- **`helm test` is the deploy gate.** In PR environments it registers a
  throwaway identity and does an authenticated round trip; against production it
  runs read-only.
