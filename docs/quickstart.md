# trying it out

Stand up the test cluster on its own, deploy an instance by hand, prove it
works, destroy it. Touches nothing in production and needs no other module.

This is phases 1–2 of [the migration plan](migration.md) done interactively,
with the same commands the CD workflows run.

**Roughly $2–4 for an afternoon**: the control plane is $0.10/hr from `apply` to
`destroy`, one small spot node carries everything, NAT is ~$0.05/hr.

## prerequisites

`tofu >= 1.10`, `helm >= 3.14`, `kubectl`, and credentials for the OMSF account
able to create a VPC, an EKS cluster, and IAM roles.

```bash
aws sts get-caller-identity --query Arn --output text
```

**Note that ARN** — it goes in `admin_principal_arns`, and without it you build a
cluster you cannot talk to. If it is an assumed-role ARN
(`arn:aws:sts::…:assumed-role/SomeRole/session`), use the underlying role ARN
(`arn:aws:iam::…:role/SomeRole`) instead.

## 1. state backend

One-time, shared with the real deployment later.

```bash
tofu -chdir=infra/opentofu/bootstrap init
tofu -chdir=infra/opentofu/bootstrap apply
tofu -chdir=infra/opentofu/bootstrap output    # note the bucket name
```

## 2. the test cluster

```bash
cd infra/opentofu/test
tofu init -backend-config="bucket=<state-bucket>" -backend-config="region=us-east-1"

tofu apply \
  -var 'admin_principal_arns=["arn:aws:iam::<account>:role/<your-role>"]' \
  -var 'deploy_pr_role_name=' \
  -var 'create_log_group=true'
```

Those two overrides are what let this stand alone: no CD role exists to grant an
access entry to, and no prod module exists to own the log group. Both go away
when you do this for real.

**Expect 15–20 minutes**, nearly all control plane.

```bash
aws eks update-kubeconfig --name alchemiscale-test --region us-east-1
kubectl get nodes          # zero — correct: Auto Mode runs none until something schedules
kubectl get storageclass   # gp3 (default)
```

## 3. an instance, by hand

What `pr-deploy.yml` does, minus the automation. Pick any published tag from
`ghcr.io/openfreeenergy/alchemiscale.org-omsf-server`.

```bash
cd ../../..    # repo root

helm upgrade --install dev charts/alchemiscale \
  --namespace dev --create-namespace \
  --values deployments/omsf/values.yaml \
  --values deployments/omsf/values-pr.yaml \
  --set clusterName=alchemiscale-test \
  --set image.tag=<tag> \
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

scripts/identity-add.sh dev -c test -n dev -t user -i you        # prints a key
scripts/identity-add-scope.sh dev -c test -n dev -t user -i you -s '*-*-*'
```

## 5. destroy it

```bash
helm uninstall dev -n dev && kubectl delete namespace dev

cd infra/opentofu/test
tofu destroy \
  -var 'admin_principal_arns=["arn:aws:iam::<account>:role/<your-role>"]' \
  -var 'deploy_pr_role_name=' \
  -var 'create_log_group=true'
```

Pass `destroy` the same `-var` flags as `apply`, or it tries to resolve a role
that isn't there. Uninstall before destroying so the EBS volume is reclaimed.
Afterwards check for a leftover NAT gateway or Elastic IP — they cost money idle,
and a partially failed destroy is how one survives.

## then the real thing

[infrastructure.md](infrastructure.md#first-time-setup) for the prod cluster,
[continuous-deployment.md](continuous-deployment.md#repository-configuration)
for wiring up CD, [migration.md](migration.md) for the order.
