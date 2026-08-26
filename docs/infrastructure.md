# infrastructure

Two EKS clusters, built from one shared OpenTofu module so they cannot
structurally drift apart.

| cluster | runs | lifetime |
| --- | --- | --- |
| `alchemiscale-prod` | one namespace per deployment (`omsf`, `openadmet`) | long-lived; changed only by release CD |
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
both clusters. The `root` and `asap` instances run outside it — `root` until it
is retired, `asap` indefinitely, since it is not managed here — so their records
live in this account's zone but resolve to hosts elsewhere. Two consequences:

- **The cluster must not touch those records.** `legacy_dns_names` both excludes
  them from ExternalDNS's configuration and denies them in its IAM policy —
  configuration is editable by anyone who can deploy the chart, permission is
  not. An entry leaves the list only when this cluster takes that record over — which for `asap` is never.
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
├── identity/            GitHub OIDC provider, the three deployer roles and the test-infra
│                        permissions boundary, the test log group, the PR scratch bucket
├── prod/                prod cluster, DNS/ACM, secrets, backups, DLM, alarms, dashboards,
│                        per-deployment identity
└── test/                test cluster only — everything here is safe to destroy
```

**Durable versus disposable is the important line, and it does not run between
prod and test.** The test cluster's log group, scratch bucket, and deployer
roles are durable — destroying the test stack must never remove the means of
bringing it back, or the logs from the run being investigated — but they are not
production, and they have to exist long before production does. CD stands the
test cluster up and deploys PR environments to it well ahead of the prod
bring-up, and it needs an AWS identity to do that with.

So they live in `identity/`, which declares nothing that depends on a cluster
and is applied once, by an operator, before either cluster exists. `prod/` looks
the release role up by name to grant it an access entry; `test/` does the same
with the PR deployer role. Apply order is **bootstrap → identity → test → prod**.

## first-time setup

To evaluate rather than deploy, use [quickstart.md](quickstart.md) — the test
cluster alone, for a few dollars, with no dependency on any of this.

Needs credentials for the OMSF account and the hosted zone already in it: the
prod apply looks that zone up by name and validates ACM certificates through it.

```bash
# 1. state bucket and encryption key (local state, applied once)
tofu -chdir=infra/opentofu/bootstrap init
tofu -chdir=infra/opentofu/bootstrap apply

# 2. identity: OIDC provider, deployer roles, test log group, scratch bucket
cd infra/opentofu/identity
cp backend.hcl.example backend.hcl           # bucket from step 1
cp terraform.tfvars.example terraform.tfvars # repository, OIDC provider flag
tofu init -backend-config=backend.hcl
tofu apply
tofu output                                  # the role ARNs CD needs as repository variables

# 3. test: cluster only (CD does this automatically thereafter)
cd ../test
cp backend.hcl.example backend.hcl
tofu init -backend-config=backend.hcl
tofu apply

# 4. prod: cluster, DNS, secrets, monitoring, per-deployment identity
cd ../prod
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars # operators, alert emails, deployments
tofu init -backend-config=backend.hcl
tofu apply
```

Identity goes first — `test/` reads the PR deployer role and log group from it,
and `prod/` grants the release role its access entry by name. Steps 3 and 4 are
independent of each other. To apply either before the identity layer exists, set
the corresponding lookup to `""` (`deploy_pr_role_name`,
`deploy_release_role_name`) and, on test, `create_log_group = true` — see
`test/variables.tf` for handing the log group over afterwards.

Each root module takes its settings from a gitignored `terraform.tfvars`
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

One S3 bucket, separate state per root module (`bootstrap/`, `identity/`,
`prod/`, `test/`), OpenTofu native locking (`use_lockfile`, no DynamoDB table),
and client-side **state encryption** via KMS — state holds cluster, IAM, and
secret-adjacent detail, so S3's at-rest encryption should not be the only thing
protecting it.

### moving a resource between root modules

Separate states means `moved` blocks do not help: they relocate an address
*within* one state. Moving a resource between root modules is a state operation,
run by an operator, and the alternative — letting one module destroy it and the
other create it — is not acceptable for anything with a name others depend on.

This applies to anyone who applied `prod/` before the `identity/` layer existed.
Check first; if the resources were never created there is nothing to do:

```bash
tofu -chdir=infra/opentofu/prod state list | grep -E 'deploy_release|deploy_pr|test_infra|test_scratch|openid_connect|log_group.test'
```

**Nothing listed** — apply `identity/` and carry on.

**Addresses listed** — import them into `identity/` first, then drop them from
`prod/`. In that order: an interrupted run leaves a resource tracked twice,
which is recoverable, rather than tracked nowhere, which needs the console to
diagnose. Addresses are identical on both sides, so only the directory changes.

```bash
cd infra/opentofu/identity
tofu init -backend-config=backend.hcl

acct=$(aws sts get-caller-identity --query Account --output text)
boundary="arn:aws:iam::${acct}:policy/alchemiscale-test-infra-boundary"

tofu import 'aws_iam_openid_connect_provider.github[0]' \
  "arn:aws:iam::${acct}:oidc-provider/token.actions.githubusercontent.com"
tofu import aws_iam_role.deploy_release        alchemiscale-deploy-release
tofu import aws_iam_role_policy.deploy_release alchemiscale-deploy-release:deploy-release
tofu import aws_iam_role.deploy_pr             alchemiscale-deploy-pr
tofu import aws_iam_role_policy.deploy_pr      alchemiscale-deploy-pr:deploy-pr
tofu import aws_iam_role.test_infra            alchemiscale-test-infra
tofu import aws_iam_policy.test_infra_boundary "$boundary"
tofu import aws_iam_role_policy_attachment.test_infra "alchemiscale-test-infra/${boundary}"
tofu import aws_cloudwatch_log_group.test      alchemiscale-test
tofu import aws_s3_bucket.test_scratch                     "alchemiscale-test-scratch-${acct}"
tofu import aws_s3_bucket_public_access_block.test_scratch "alchemiscale-test-scratch-${acct}"
tofu import aws_s3_bucket_lifecycle_configuration.test_scratch "alchemiscale-test-scratch-${acct}"
tofu import aws_iam_role.test_scratch          alchemiscale-test-scratch
tofu import aws_iam_role_policy.test_scratch   alchemiscale-test-scratch:scratch-object-store
```

Then `tofu plan`, and expect **no creates and no destroys**. Three in-place
updates are expected and correct:

- **tags** — these resources inherited `cluster = prod` from the prod provider's
  default tags and now carry `layer = identity` instead;
- **the test log group** gains `cluster = test`, which is what it should have
  had all along;
- **the test-infra boundary policy** — one statement renamed from
  `StateBucketOnlyForState` to `NeverTouchProtectedBuckets` (same actions, same
  bucket ARNs; the old name described a bucket the statement never referred to),
  and one added, `NeverTouchDurableRoles`, closing a gap that predates the move:
  `ConfineIAMWrites` permits role names beginning with `alchemiscale-test`,
  which is also the prefix of the lifecycle role itself and of the PR scratch
  role, so the reaper could delete the credentials it runs as.

Anything else in the plan means a variable differs from what `prod/` was applied
with — `test_scratch_bucket_name`, `github_repository`, retention — and should
be reconciled in `identity/terraform.tfvars` before applying. Apply, then remove
the same addresses from prod:

```bash
cd ../prod
tofu init -backend-config=backend.hcl
tofu state pull > /tmp/prod-state-backup.json   # the rollback, should any of this go wrong

for addr in 'aws_iam_openid_connect_provider.github[0]' \
            aws_iam_role.deploy_release aws_iam_role_policy.deploy_release \
            aws_iam_role.deploy_pr aws_iam_role_policy.deploy_pr \
            aws_iam_role.test_infra aws_iam_policy.test_infra_boundary \
            aws_iam_role_policy_attachment.test_infra \
            aws_cloudwatch_log_group.test \
            aws_s3_bucket.test_scratch aws_s3_bucket_public_access_block.test_scratch \
            aws_s3_bucket_lifecycle_configuration.test_scratch \
            aws_iam_role.test_scratch aws_iam_role_policy.test_scratch; do
  tofu state rm "$addr"
done

tofu plan   # must show no destroys
```

`tofu state rm` forgets a resource without touching it in AWS, which is exactly
what is wanted here — the resource is already tracked by `identity/`. The
`state mv -state-out=…` route works too, but it pulls both states to local
files and pushes them back, and a mistake there loses state rather than
duplicating it.

The same shape handles a test log group created with `create_log_group = true`
(quickstart's standalone path) when the identity layer arrives later:
`tofu -chdir=…/identity import aws_cloudwatch_log_group.test alchemiscale-test`,
then `tofu -chdir=…/test state rm 'aws_cloudwatch_log_group.test[0]'`.

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
would make it the largest line on the bill. A version's support dates are not
folklore; ask:

```bash
aws eks describe-cluster-versions \
  --query 'clusterVersions[].{v:clusterVersion,default:defaultVersion,standardEnds:endOfStandardSupportDate}' --output table
aws eks describe-cluster --name alchemiscale-prod --query 'upgradePolicy.supportType'
```

`supportType: EXTENDED` means you are already paying the higher rate.

Both clusters set `cluster_support_type = "STANDARD"`, so AWS auto-upgrades a
cluster rather than letting it slide into extended billing. That is a deliberate
trade — an unattended minor upgrade is a smaller problem than a 6x bill nobody
notices, and AWS gives months of warning. Keeping `kubernetes_version` current
means it never fires.

The two clusters treat versions differently, on purpose:

- **test** leaves `kubernetes_version = null`, so EKS picks its current default
  at creation. The lifecycle workflow recreates this cluster routinely, so it
  drifts forward on its own and always exercises the version AWS currently
  recommends. Nothing upgrades in place — the attribute is computed, so an
  existing cluster stays put until it is next recreated.
- **prod** pins a version explicitly. Control-plane upgrades there are
  deliberate, planned, and taken one minor at a time.

The useful consequence: test leads prod, so the chart meets a new Kubernetes
version in PR environments before production does, and `tofu -chdir=…/test
output kubernetes_version` diverging from prod's pin is the prompt to schedule
the prod upgrade. If you would rather have exact parity, pin test to the same
version.

Minor versions cannot be skipped — 1.33 to 1.36 is three sequential in-place
upgrades of roughly twenty minutes each — which is why recreating a disposable
test cluster beats upgrading it.

(There is also an `aws_eks_cluster_versions` data source that can resolve "the
newest version in standard support" at plan time. It is deliberately not used:
it would re-pin on every apply, turning an unrelated change into an unplanned
control-plane upgrade, and it can produce a multi-minor jump that EKS rejects.) Cluster-service chart versions are pinned in
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
