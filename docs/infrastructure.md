# infrastructure

Two EKS clusters, built from one shared OpenTofu module so they cannot
structurally drift apart.

| cluster | runs | lifetime |
| --- | --- | --- |
| `alchemiscale-prod` | one namespace per deployment (`omsf`, `asap`, `openadmet`) | long-lived; changed only by release CD |
| `alchemiscale-test` | ephemeral `<deployment>-pr-<n>` namespaces | created on demand, destroyed when idle |

Both run **EKS Auto Mode**: AWS operates node lifecycle (Karpenter), load
balancer provisioning, EBS CSI, and core networking. There is no managed node
group and no controller node, so an idle test cluster runs zero EC2 instances
and prod's steady state is two to three general-purpose nodes carrying
everything. The only self-managed services are Fluent Bit, metrics-server, and —
prod only — ExternalDNS, External Secrets Operator, and the
`amazon-cloudwatch-observability` add-on.

## node pools

Both clusters use AWS's built-in `general-purpose` Auto Mode node pool
(`builtin_node_pools`), so PR environments run the same node configuration as
production — one less difference between where changes are tested and where they
land. AWS owns the node role, security groups, and instance profile end to end.

Setting `builtin_node_pools = []` switches to the module's own
NodeClass/NodePool, which is what the `nodepool_*` variables configure and what
can provision **spot** capacity. That is deliberately not the default:

- Production is on-demand regardless, so it gains nothing.
- On test it saves under $10/mo on a cluster that is idle most of the month.
- PR environments run neo4j on a ReadWriteOnce volume. Karpenter acts on spot
  *rebalance recommendations*, which fire far more often than real interruptions
  — one arrived 90 seconds into a node's life during bring-up — and each one
  detaches and reattaches a database volume, potentially mid-test. A flaky PR
  signal costs more than the saving.

If you do enable it, the NodeClass must select **only** the EKS-managed cluster
security group. Attaching the module's node security group — alone or alongside
— yields nodes that register and then sit `NotReady` forever with `cni plugin
not initialized`, because Auto Mode's pod ENIs inherit the node's security
groups. AWS's own generated NodeClass selects exactly one group; match it. And
constrain the instance types: of the 124 candidates in us-east-1, only 21 have
sub-5% interruption rates, and Karpenter optimises for price, not stability.

## account model

The OMSF account owns the `alchemiscale.org` registration, the hosted zone, and
both clusters. The legacy `root` and `asap` EC2 instances stay in the Chodera Lab
account until each is cut over — so their records live in this account's zone
but resolve to hosts in the other one. Two consequences:

- **The cluster must not touch those records.** `legacy_dns_names` both excludes
  them from ExternalDNS's configuration and denies them in its IAM policy —
  configuration is editable by anyone who can deploy the chart, permission is
  not. An entry leaves the list at that deployment's cutover.
- **Their operators cannot edit them unaided.** `legacy_dns_editor_account_ids`
  grants the legacy account a role scoped to exactly those record names. Elastic
  IPs on those hosts make this mostly moot; the role covers the rest.

## layout

```
infra/opentofu/
├── modules/cluster/     VPC + EKS (Auto Mode) + NodePool + StorageClass + cluster services
│   └── charts/          cluster-scoped resources, applied through the helm provider so
│                        no Kubernetes API is needed at plan time
├── bootstrap/           state bucket + KMS key (local state; applied once, by hand)
├── prod/                prod cluster, DNS/ACM, secrets, backups, alarms, OIDC roles,
│                        and the test cluster's durable resources
└── test/                test cluster only — everything here is safe to destroy
```

**Durable versus disposable is the important line.** The test cluster's log
group, scratch bucket, and PR deployer role live in `prod/`, so destroying the
test stack can never remove the means of bringing it back, or the logs from the
run that failed.

## first-time setup

To evaluate rather than deploy, use [quickstart.md](quickstart.md) — the test
cluster alone, for a few dollars, with no dependency on any of this.

Needs credentials for the OMSF account and the hosted zone already in it: the
prod apply looks that zone up by name and validates ACM certificates through it.

```bash
# 1. state bucket and encryption key (local state, applied once)
tofu -chdir=infra/opentofu/bootstrap init
tofu -chdir=infra/opentofu/bootstrap apply

# 2. prod: cluster, DNS, secrets, monitoring, IAM
cd infra/opentofu/prod
cp backend.hcl.example backend.hcl           # bucket from step 1
cp terraform.tfvars.example terraform.tfvars # operators, alert emails, deployments
tofu init -backend-config=backend.hcl
tofu apply

# 3. test: cluster only (CD does this automatically thereafter)
cd ../test
cp backend.hcl.example backend.hcl
tofu init -backend-config=backend.hcl
tofu apply
```

Prod goes first — `test/` reads the PR deployer role and log group from it. For
the reverse order, set `deploy_pr_role_name = ""` and `create_log_group = true`
(see `test/variables.tf` for handing the log group over afterwards).

Both root modules take their settings from a gitignored `terraform.tfvars`
copied from the `.example` beside it. Values for variables that a root module
doesn't declare are only *warned* about, not rejected — so if a setting appears
to do nothing, check it exists in that root module's `variables.tf` and is
passed through to `modules/cluster`.

Import the existing `alchemiscale` log group before the first prod apply, so
post-migration logs land beside the historical ones:

```bash
tofu -chdir=infra/opentofu/prod import aws_cloudwatch_log_group.prod alchemiscale
```

Secrets Manager entries are created with generated values and then ignored by
OpenTofu — rotate with `aws secretsmanager put-secret-value` and ESO picks the
new value up.

## state

One S3 bucket, separate state per root module, OpenTofu native locking
(`use_lockfile`, no DynamoDB table), and client-side **state encryption** via
KMS — state holds cluster, IAM, and secret-adjacent detail, so S3's at-rest
encryption should not be the only thing protecting it.

## verify on first bring-up

Five things that depend on AWS behaviour worth confirming once rather than
assuming:

1. **Volume tags.** The gp3 StorageClass sets `tagSpecification_1` so volumes
   carry `alchemiscale-snapshot=true`, which is how the DLM policy finds them.
   Check the first provisioned volume actually has it.
2. **Container Insights metric names.** The alarms use enhanced Container
   Insights names (`pod_number_of_container_restarts`, `pod_status_pending`,
   `node_cpu_utilization`); confirm they are published. An alarm on a metric
   that never arrives never fires. The neo4j disk alarm deliberately doesn't
   depend on this — the chart publishes that metric from a sidecar.
3. **IngressGroup support.** All deployments share one ALB via
   `alb.ingress.kubernetes.io/group.name`. If Auto Mode declines it, blank
   `ingress.groupName` and budget for one ALB per deployment.
4. **Alerting end to end.** `aws cloudwatch set-alarm-state` and confirm it
   reaches the SNS subscribers.
5. **The legacy-record deny actually denies.** A `Deny` with a misspelled
   condition key never matches, so it fails open while looking correct. Assume
   the ExternalDNS role, attempt a change to `api.alchemiscale.org` (expect
   `AccessDenied`), then one to a deployment's own record (expect success).

## upgrades

Keep both clusters inside the EKS **standard support window**. Out of window is
billed at $0.60/hr instead of $0.10/hr — an extra ~$365/mo for prod alone, which
would make it the largest line on the bill.

Bump `kubernetes_version` in `prod/variables.tf` and `test/variables.tf` in the
same change, and let test go first. Cluster-service chart versions are pinned in
`modules/cluster/variables.tf` (`chart_versions`), so those upgrades are a
reviewable diff rather than whatever was latest that day.

## cost

Roughly **$500–700/mo**, against ~$300/mo for the two EC2 hosts replaced (~$440
once a third host for `openadmet` is counted). The prod floor — control plane,
ALB, NAT, EBS, CloudWatch — is ~$183/mo and irreducible; everything else is EC2:

1. **Test-cluster spin-down** — already automatic, and the dominant lever: the
   test cluster costs nothing in months with no labelled PRs, which matters far
   more than the node pricing on it.
2. **Right-size requests** from observed usage, then let Auto Mode consolidate.
3. **1-year Compute Savings Plan** once sizing stabilises (~$65–90/mo) — buying
   one on wrongly-sized nodes locks in the mistake.
4. **Graviton** (add `arm64` to `nodepool_architectures`) once multi-arch images
   exist and every pinned conda-forge package has a `linux-aarch64` build.

Cost-allocation tags (`cluster=prod|test`) keep the two separable on the bill.
