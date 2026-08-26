# migration

How the docker-compose-on-EC2 instances become EKS deployments. Each phase is
independently mergeable and leaves the running EC2 setup untouched until its
cutover.

| phase | what lands |
| --- | --- |
| 1 | `infra/opentofu` — shared module + bootstrap, identity, and test root modules; apply and verify |
| 2 | `charts/alchemiscale`, per-deployment values, chart CI |
| 3 | build/PR/teardown/lifecycle workflows, exercised on a real PR |
| 4 | prod cluster + `release-deploy.yml` + environments; `openadmet` launches |
| 5 | `omsf` launched alongside `root` |

Phases 1–3 are entirely test cluster and PR machinery — cheap to get wrong,
which is why they go first. Tune NodePool sizing and smoke-test flakiness there.
[quickstart.md](quickstart.md) walks the test cluster of phases 1–2 by hand in
an afternoon, standalone.

**Phase 3 does not wait on phase 4.** The roles CD authenticates to AWS with are
applied in phase 1, from
[`identity/`](../infra/opentofu/identity) — a root module that needs no cluster,
so PR environments can be exercised for real long before production exists. They
were originally declared in `prod/`, which made phase 3 impossible as written;
[issue #24](https://github.com/OpenFreeEnergy/alchemiscale.org-deployment/issues/24)
moved them.

## done: DNS

The registration and hosted zone are in the OMSF account; the legacy instances
are untouched in the Chodera Lab account and still serve the same names. Two
loose ends:

- Set `legacy_dns_editor_account_ids` so the legacy account can repoint its own
  records. Check whether those hosts have Elastic IPs — if not, an instance
  replacement changes the address and someone needs that role.
- Keep the old hosted zone for a month. It is the rollback: one registrar change
  puts resolution back.

## phase 4 — prod bring-up

1. `tofu -chdir=infra/opentofu/prod apply` ([setup](infrastructure.md#first-time-setup)).
   The identity layer is already applied from phase 1, so the release role
   exists and picks up its access entry on this apply.
2. Verify controllers with a hello-world Ingress: ExternalDNS creates the record,
   the ALB comes up, ACM terminates TLS.
3. Fire a test alarm, confirm it reaches SNS.
4. Rehearse a release into a throwaway `dev` namespace.
5. Launch **`openadmet`** through the pipeline for real — no EC2 host, no users,
   so it is greenfield and the lowest-stakes first outing for the machinery.

## phase 5 — cutover

### `openadmet`

Nothing to cut over; born on EKS in phase 4. Delete its compose configuration
once the chart is authoritative.

### `asap`

Not migrated. It keeps running on its own host, outside this repository's
automation: no chart values, no namespace, no release target, and its DNS
records stay in `legacy_dns_names` indefinitely so the cluster never claims
them. Its environment files stay in `deployments/asap/` and its images remain
buildable by hand through `build-images.yml`.

### `root` → `omsf` — parallel run

Not a rename in place. `omsf` launches on EKS as a new instance while `root`
stays up, frozen, on its EC2 host in the legacy account for **three months**.

- `omsf` starts with a **fresh neo4j and a new S3 prefix**. `root` stays live and
  writable, so restoring a snapshot into `omsf` would fork state.
- **Identities are re-onboarded on request**, not copied; stale ones are left
  behind.
- `root` is frozen: no deploys, build workflow retired, compose stack untouched.
  Its names keep pointing at the EC2 host, and the EKS certificates only ever
  cover `*.omsf.alchemiscale.org`.
- [`deployments/root`](../deployments/root) stays on `main` for the window so its
  operators have the configuration to hand. It has **no `values.yaml`**, and both
  deploy workflows select on the presence of chart values — so CD cannot reach it
  by construction, not by a name check someone could forget. Treat any commit
  touching it as a mistake.
- Announce availability and the retirement date together; update the
  alchemiscale docs and client-setup instructions. HPC and Folding@Home services
  on `root` need repointing within the window.
- At the end: final dump, archive it and the S3 prefix in the legacy account,
  **remove** the legacy DNS records (a clear failure beats silently resolving to
  different state), decommission the host, delete `deployments/root`, drop the
  README deprecation row.

## after cutover

- Delete the compose-era scale and ops docs in favour of these.
- Retire the `release` branch; releases are the trigger now.
- Revisit sizing with a month of Container Insights data, then consider a
  Savings Plan.
