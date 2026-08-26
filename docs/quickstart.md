# trying it out

Stand up the test cluster on its own, deploy an instance by hand, prove it
works, destroy it. Touches nothing in production and needs no other module.

This is phases 1–2 of [the migration plan](migration.md) done interactively,
with the same commands the CD workflows run.

**Roughly $2–4 for an afternoon**: the control plane is $0.10/hr from `apply` to
`destroy`, one small node carries everything, NAT is ~$0.05/hr.

## prerequisites

`tofu >= 1.10`, `helm >= 3.14`, `kubectl`, and credentials for the OMSF account
able to create a VPC, an EKS cluster, and IAM roles.

```bash
export AWS_PROFILE=<your-profile>
aws sso login                     # if it's an SSO profile; tokens expire
export AWS_REGION=us-east-1       # must match `region` in the tfvars below
```

**Set the region explicitly.** The OpenTofu providers take theirs from
`var.region` regardless of what your profile says, so a profile pointing
elsewhere leaves you with a cluster in one region and CLI commands looking in
another — which shows up as `No cluster found for name`.

You do **not** need to put your own ARN in `admin_principal_arns`: whoever runs
`apply` is granted cluster-admin automatically, and listing yourself is
deduplicated. To grant *other* operators access, use their IAM role ARN — ask
IAM for it rather than rewriting the STS one, since SSO roles carry a path that
`sts get-caller-identity` doesn't show:

```bash
arn=$(aws sts get-caller-identity --query Arn --output text)  # …:assumed-role/RoleName/session
aws iam get-role --role-name "$(echo "$arn" | cut -d/ -f2)" --query Role.Arn --output text
```

## 1. state backend

One-time, shared with the real deployment later.

```bash
tofu -chdir=infra/opentofu/bootstrap init
tofu -chdir=infra/opentofu/bootstrap apply
tofu -chdir=infra/opentofu/bootstrap output    # note the bucket name
```

## 2. the test cluster

Put settings in files rather than on the command line: `destroy` needs the same
values as `apply`, and a file can't be forgotten — or mangled by a shell that
handles quoting differently, as xonsh does with `-backend-config="…"`.

```bash
cd infra/opentofu/test
cp backend.hcl.example backend.hcl              # fill in the bucket from step 1
cp terraform.tfvars.example terraform.tfvars    # both gitignored

tofu init -backend-config=backend.hcl
tofu apply
```

For a standalone cluster `terraform.tfvars` needs `deploy_pr_role_name = ""` and
`create_log_group = true` — both normally come from the prod root module, which
doesn't exist yet.

**Expect 15–20 minutes**, nearly all control plane.

```bash
aws eks update-kubeconfig --name alchemiscale-test --region us-east-1
kubectl get nodes          # zero — correct: Auto Mode runs none until something schedules
kubectl get storageclass   # gp3 (default)
```

## 3. an instance, by hand

What `pr-deploy.yml` does, minus the automation.

Use **`openadmet`**: it has published images and no users yet, so a scratch
deploy of it carries no weight at all. (`omsf` is new in this work, so
`alchemiscale.org-omsf-server` stays empty until CD publishes it on a labelled
PR or a release.) Check which tags exist before picking one:

```bash
pkg=alchemiscale.org-openadmet-server
token=$(curl -s "https://ghcr.io/token?scope=repository:openfreeenergy/$pkg:pull&service=ghcr.io" | jq -r .token)
curl -s -H "Authorization: Bearer $token" "https://ghcr.io/v2/openfreeenergy/$pkg/tags/list" | jq -r '.tags[]'
```

Prefer a `sha-` tag over a branch name: it is tied to one commit rather than a
head that moves, which is the same reason CD deploys by digest.

```bash
cd ../../..    # repo root

helm upgrade --install dev charts/alchemiscale \
  --namespace dev --create-namespace \
  --values deployments/openadmet/values.yaml \
  --values deployments/openadmet/values-pr.yaml \
  --set clusterName=alchemiscale-test \
  --set image.tag=sha-fb30e25 \
  --set s3.bucket=unused --set s3.prefix=unused \
  --wait --timeout 20m
```

Give it the full timeout — the first deploy waits on a node and a multi-GB image
pull. No AWS identity is wired up, so the object store is non-functional: enough
for `/ping`, identities, and an authenticated round trip, but writing results
will fail. That is what the Pod Identity association in the real PR workflow
provides.

## 4. prove it works

```bash
helm test dev -n dev --logs
```

The same smoke test CD gates on: pings both APIs, registers a throwaway identity
against neo4j, does an authenticated client round trip. To poke at it yourself:

```bash
kubectl -n dev port-forward svc/alchemiscale-client-api 1840:1840 &
curl -s localhost:1840/ping

scripts/identity-add.sh openadmet -c test -n dev -t user -i you        # prints a key
scripts/identity-add-scope.sh openadmet -c test -n dev -t user -i you -s '*-*-*'
```

## 5. destroy it

```bash
helm uninstall dev -n dev && kubectl delete namespace dev

tofu -chdir=infra/opentofu/test destroy
```

Uninstall before destroying so the EBS volume is reclaimed. Afterwards check for
a leftover NAT gateway or Elastic IP — they cost money idle, and a partially
failed destroy is how one survives.

## when it doesn't work

**`No cluster found for name`** — the CLI is looking in a different region than
`var.region`. See the prerequisites.

**A value in `terraform.tfvars` does nothing.** OpenTofu only *warns* about
values for undeclared variables, then carries on with the default. If a setting
has no effect, check it is declared in the root module's `variables.tf` and
passed to the module — not just declared in `modules/cluster`.

**Nodes stay `NotReady` with `cni plugin not initialized`.** The node registers
and kubelet runs, but pods sit `Pending` against a `node.kubernetes.io/not-ready`
taint. On Auto Mode this means the NodeClass attaches the wrong security groups:
it must select the EKS-managed cluster security group and **nothing else**.
Adding the module's node security group alongside it breaks pod networking just
as thoroughly as using it alone. Compare against what AWS generates for its
built-in pools:

```bash
kubectl get nodeclass -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.securityGroupSelectorTerms}{"\n"}{end}'
```

**A Helm release times out on a cold cluster.** The first release waits out node
provisioning and an image pull; the module allows 900s (`helm_timeout`). If you
hit that ceiling, the node is the problem, not the timeout — check
`kubectl get nodes` before touching anything else.

## then the real thing

[infrastructure.md](infrastructure.md#first-time-setup) for the prod cluster,
[continuous-deployment.md](continuous-deployment.md#repository-configuration)
for wiring up CD, [migration.md](migration.md) for the order.
