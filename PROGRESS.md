# Progress

_Last updated: 2026-07-27_

Build/status log for the Dynamo Lab. See [README.md](README.md) for usage,
[CONTEXT.md](CONTEXT.md) for vocabulary, and [docs/adr/](docs/adr/) for the design decisions.

## Milestones

- [x] **Design grilling** — 12 architectural decisions locked (ADR 0001–0008).
- [x] **Scaffold generated** — Terraform, platform Helm values, fleet CRDs, chaos, load, glue.
- [x] **Verification pass 1** (consistency + correctness) — 1 blocker + 7 major + 6 minor fixed.
- [x] **Cleanup/audit pass 2** (5 lenses) — 25 confirmed fixed, 2 rejected.
- [x] **Improvement/audit pass 3** (deploy-readiness · security · feasibility · DX) —
  15 confirmed fixed (2 blockers), 12 rejected.
- [x] **GitHub-ready** — Apache-2.0 LICENSE, CI (shellcheck · yamllint · `terraform
  fmt`/`validate`), issue/PR templates, CODEOWNERS, Dependabot, committed provider
  lock files. All three linters verified green locally. Published as a public repo.
- [x] **Fleet + operator verified against Dynamo v1.3.0** — resolved 46 `# VERIFY:` markers in
  the fleet manifests, operator install, and metrics wiring against upstream primary sources;
  fixed 6 real defects (Pass 4 below). Docs/source-verified, not yet live-verified.
- [x] **Terraform plan validated (read-only)** — both roots plan clean against the real account
  (209468748526, us-west-2): bootstrap 5 to add, main **91 to add / 0 change / 0 destroy**, no
  warnings. Nothing applied. Infra version markers resolved in the same pass (Pass 5 below).
- [ ] **First `make up` against AWS** — NOT yet run. Nothing has been applied to a real account.
- [ ] **Resolve remaining `# VERIFY` markers** (66 left: platform / observability / coordination /
  chaos / load / scripts). The **Terraform/infra layer is now fully resolved.**
- [ ] **First end-to-end experiment** — spike + chaos on the disaggregated fleet.

## What's built

A declarative, GPU-free Dynamo fleet on EKS with full observability, Chaos Mesh fault
injection, and k6 spike load — driven by `make up/down/pause/resume`, `fleet-up`,
`chaos-start/stop`, `load-start/stop`. Architecture and layout are in the README.

## Repository & CI

Static-only CI (`.github/workflows/ci.yml`) — **no AWS calls** — runs on every push/PR:

- **shellcheck** (`--severity=warning`) on `scripts/*.sh` + `scripts/lib/*.sh`.
- **yamllint** (`.yamllint.yml`, tuned for Helm values / k8s manifests) on all YAML.
- **terraform** `fmt -check` + `init -backend=false` + `validate` on both roots.

All three pass locally. `common.sh` carries a scoped `# shellcheck disable=SC2034`
(its config vars are consumed by the scripts that source it). Provider lock files for
`terraform/bootstrap` and `terraform/main` are committed (linux_amd64 + darwin_arm64).

Dependabot proposes minor/patch bumps for GitHub Actions + Terraform, and is configured to
**ignore Terraform majors** (they need deliberate migration, not auto-merge). The coordinated
v6/v21 migration has since been done by hand: `terraform/main` now runs on `aws` provider v6,
`terraform-aws-modules` **vpc v6 / eks v21 / iam v6** (+ eks `//modules/karpenter` v21), and
`helm` v3 / `kubernetes` v3. All the breaking renames are resolved — eks `cluster_name`→`name`,
`cluster_version`→`kubernetes_version`, `cluster_endpoint_public_access*`→`endpoint_public_access*`,
`cluster_addons`→`addons`; the iam submodule dropped its `-eks` suffix and `role_name`→`name`
(with `use_name_prefix=false` to keep the fixed name); karpenter dropped `enable_pod_identity`
and `enable_v1_permissions` (both now default behavior). `terraform validate` + `fmt` pass and
the provider lock is regenerated. **`terraform plan` has now been run** (read-only, via a temporary
local-backend override so no state bucket was created) — both roots plan clean, so the migration is
structurally valid; still not AWS-*applied*. The OIDC-provider-host and addon-default changes noted
in the v21 upgrade guide only matter for an already-deployed cluster, so they don't affect this
first apply.

## Audit history

**Pass 1 — consistency + correctness.** Cross-file seams from the parallel build: wrong Helm
values paths, dashboards/chaos-bridge never applied, `PROFILE` not switchable, k6 targeting a
non-existent frontend service, S3 locking off, Karpenter installed twice. All fixed.

**Pass 2 — 5-lens cleanup** (shell · terraform · k8s · wiring · simplify). 25 confirmed.
Highlights: `platform.sh` referenced a non-existent Chaos Mesh values file (blocker);
decoupled the two Dynamo chart versions from the mocker image tag; `render()` now dies loudly
without `envsubst`; fixed a subtle k6/`envsubst` token collision (distinct `${K6_*}` tokens);
Terraform floor → `>= 1.10`; subnet CIDR overlap; shipped `podmonitor-fleet.yaml`.

**Pass 3 — deploy-readiness / security / feasibility / DX.** 15 confirmed, 12 rejected.
Highlights:

- **Blocker:** operator/CRDs charts pointed at `oci://nvcr.io` — NGC serves them over **HTTPS**
  (`helm repo add https://helm.ngc.nvidia.com/nvidia/ai-dynamo`). Fixed.
- **Blocker:** the 3-member etcd quorum (hard anti-affinity) couldn't schedule on 2 system
  nodes with Karpenter installed later — **system node group raised to 3** (preserves ADR 0003
  HA). `pause`/`resume` updated to match.
- **Cost leak:** `make down` left ~45 GB+ of orphaned EBS (StatefulSet/persistence PVCs helm
  doesn't remove) billing forever — contradicting `$0 idle`. `down` now deletes PVCs before
  `terraform destroy`, in a safe teardown order (fleet → platform → scale Karpenter to 0 →
  NodeClaims → PVCs → destroy), behind a **typed confirmation gate** (`FORCE=1` to bypass).
- **Security:** `dev.tfvars` was silently ignored (`infra.sh` never passed `-var-file`), so a
  user's `cluster_endpoint_public_access_cidrs` lockdown never applied — now honored.
- **Wiring the node split (ADR 0008):** tainted the Karpenter `workers` NodePool and steered
  only the mocker workers onto it, so the planner's pod-scaling triggers node scaling.
- Added a default encrypted **gp3 StorageClass** (PVCs had no StorageClass); pinned the fleet
  image to `${DYNAMO_VERSION}`; planner `optimization_target` `none` → `load` (later corrected to
  `throughput` in Pass 4); fleet readiness now selects the `nvidia.com/dynamo-component-type` label.

**Pass 4 — fleet & operator verification against Dynamo v1.3.0** (parallel research +
adversarial review, all against primary upstream sources: repo files at tag `v1.3.0`, the
operator Go source, the planner Python source, docs.nvidia.com/dynamo). Resolved 46 `# VERIFY:`
markers and fixed 6 defects:

- **`dynamo-crds` chart is gone at v1.3.0** — CRDs ship in the operator image (`crd-apply` init
  container, `upgradeCRD` default true). Dropped the separate chart install + `DYNAMO_CRDS_VERSION`
  pin; `platform.sh` now installs only `dynamo-platform`.
- **Operator had no NATS address** — bundled etcd/NATS subcharts are disabled but
  `dynamo-operator.natsAddr`/`etcdAddr` were never set. Added, pointing at the lab's HA plane.
- **Planner would crash** — `optimization_target: "load"` requires prefill/decode threshold keys
  or it raises at config validation; switched to `"throughput"` (the default, which force-enables
  load scaling for non-SLA targets — the lab's intent). The README said the invalid `"none"`.
- **Dead metrics scrape targets** — the Frontend declared a `:8081 metrics` port but never set
  `DYN_SYSTEM_PORT` (its system server is off by default, `-1`), and the Planner binds `9085`, not
  the declared `8081`. Added `DYN_SYSTEM_PORT=8081` (Frontend) and `PLANNER_PROMETHEUS_PORT=8081`
  (Planner).
- **Wrong operator metrics keys** — `metrics.enabled` / `metrics.serviceMonitor.enabled` don't
  exist in the v1.3.0 subchart; the key is `metricsService.enabled`. Fixed.
- Confirmed-correct (markers resolved, no value change): image `dynamo-planner:1.3.0` (CPU-only,
  ships the mocker), the etcd discovery annotation, the DGD schema (services map, `componentType`,
  inline `extraPodSpec` PodSpec, cpu/memory resources), mocker CLI flags, env var names, and the
  `<dgd>-frontend` Service name.

**Pass 5 — infra version hardening + first read-only plan** (against the real account, no apply).
Verified the pinned infra versions against primary sources (AWS EKS version calendar, Karpenter
release/compat docs) and bumped the aged ones, then confirmed both Terraform roots plan clean:

- **EKS `1.31` → `1.36`** — 1.31 had rolled into paid extended support (standard ended 2025-11-26);
  1.36 is the latest with standard support through 2027-08-02. Structurally identical plan.
- **Karpenter chart `1.0.8` → `1.14.0`** — latest stable; the compat matrix requires ≥1.13 for K8s
  1.36. Plan shows `chart=karpenter version=1.14.0`.
- **AL2023 AMI alias confirmed** — the node group's SSM lookup resolves
  `AL2023_x86_64_STANDARD` → `1.36.2-20260724` in-plan.
- **dev.tfvars + endpoint lockdown** — public API `public_access_cidrs` pinned to the egress `/32`.
- **example.tfvars packaging fix** — un-ignored so the README's copy step works on a fresh clone.

The plan was run with a temporary local-backend override (deleted after) so no S3 state bucket was
created — a true read-only validation. `terraform fmt`/`validate` still pass.

## Outstanding — before the first `make up`

Never applied to AWS. The fleet manifests + Dynamo operator install are now verified against
v1.3.0 (Pass 4); the remaining `grep -rn VERIFY .` markers (80) live in the other layers:

1. **Platform chart versions** — etcd, NATS, kube-prometheus-stack, Loki, Tempo, promtail, and
   chaos-mesh chart versions (`scripts/platform.sh`), plus the bitnami image-repo relocation.
2. **Live-only fleet checks** — the component-type pod labels the operator actually stamps (the
   disagg chaos selectors assume the alpha-era `worker` + `sub-component-type` pairing), and the
   `metricsService`/PodMonitor scrape once a cluster exists.
3. **Infra versions — RESOLVED (Pass 5).** EKS control-plane `1.31` → **`1.36`** (1.31 had aged
   into paid *extended* support; 1.36 is the latest with standard support to 2027-08-02). Karpenter
   helm chart `1.0.8` → **`1.14.0`** (latest; supports K8s 1.36, needs ≥1.13). AL2023 AMI alias
   `AL2023_x86_64_STANDARD` confirmed correct (plan resolves it to `1.36.2-20260724`). The stale
   `aws 5.x` comment in `terraform/bootstrap/versions.tf` corrected (it is on 6.x). Only the
   **bitnami/etcd tag** remains — that is a *platform*-layer marker, not Terraform.
4. **Security — DONE.** `terraform/main/dev.tfvars` created (gitignored) locking
   `cluster_endpoint_public_access_cidrs` to the operator's egress `/32`; the plan confirms the
   cluster's `public_access_cidrs` is the single `/32` (all other `0.0.0.0/0` are node egress /
   NACL / NAT default routes). Refresh the CIDR if your egress IP changes.
   Also fixed a packaging bug: `example.tfvars` was matched by the `*.tfvars` gitignore rule and
   so never committed (a fresh clone lacked the template the README says to copy) — added an
   `!example.tfvars` exception.
5. **Prereqs on your machine**: `terraform >= 1.10`, `envsubst` (gettext), `aws`/`kubectl`/`helm`.
   The system node group is **3× m7i.large** (etcd HA).

## Known limitations

- Never deployed. The fleet + operator specifics are verified against v1.3.0 (docs/source, not
  live); the observability/coordination/chaos/infra layers are still best-effort, `# VERIFY`-tagged.
- Trace→logs correlation (Tempo→Loki `service_name`) is PLAUSIBLE-only until verified live.
- The chaos annotation bridge installs its Python deps at pod start (no custom image); fine for
  a lab, bake an image if you want it hardened.
