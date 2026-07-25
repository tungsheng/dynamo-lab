# Progress

_Last updated: 2026-07-25_

Build/status log for the Dynamo Lab. See [README.md](README.md) for usage,
[CONTEXT.md](CONTEXT.md) for vocabulary, and [docs/adr/](docs/adr/) for the design decisions.

## Milestones

- [x] **Design grilling** — 12 architectural decisions locked (ADR 0001–0008).
- [x] **Scaffold generated** — Terraform, platform Helm values, fleet CRDs, chaos, load, glue.
- [x] **Verification pass 1** (consistency + correctness) — 1 blocker + 7 major + 6 minor fixed.
- [x] **Cleanup/audit pass 2** (5 lenses) — 25 confirmed fixed, 2 rejected.
- [x] **Improvement/audit pass 3** (deploy-readiness · security · feasibility · DX) —
  15 confirmed fixed (2 blockers), 12 rejected.
- [ ] **First `make up` against AWS** — NOT yet run. Nothing has been applied to a real account.
- [ ] **Resolve remaining `# VERIFY` markers** against a pinned Dynamo release (see below).
- [ ] **First end-to-end experiment** — spike + chaos on the disaggregated fleet.

## What's built

A declarative, GPU-free Dynamo fleet on EKS with full observability, Chaos Mesh fault
injection, and k6 spike load — driven by `make up/down/pause/resume`, `fleet-up`,
`chaos-start/stop`, `load-start/stop`. Architecture and layout are in the README.

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
  image to `${DYNAMO_VERSION}`; planner `optimization_target` `none` → `load`; fleet readiness
  now selects the operator's `nvidia.com/dynamo-component-type` label.

## Outstanding — before the first `make up`

Never applied to AWS. Resolve these `# VERIFY:` markers (`grep -rn VERIFY .`) against the
Dynamo release you pin:

1. **Versions**: `DYNAMO_VERSION=1.3.0` (dynamo-planner image — must ship the mocker wheel,
   CPU-only), `DYNAMO_CRDS_VERSION=0.9.1`, `DYNAMO_PLATFORM_VERSION=1.3.0`, and the NGC chart
   repo URL + chart names.
2. **Fleet schema**: `DynamoGraphDeployment` fields; the planner `--config`
   (`optimization_target: "load"`); the `extraPodSpec` nodeSelector/tolerations field path for
   the worker node-split; the Frontend/Planner `metrics` port (`DYN_SYSTEM_PORT=8081`, and
   whether it must be set in their envs to bind).
3. **Labels**: the operator's `nvidia.com/dynamo-component-type` pod label (used by
   `podmonitor-fleet.yaml`, `fleet.sh` readiness, and the chaos selectors) and the
   `<dgd>-frontend` Service name k6 targets.
4. **Infra versions**: EKS `1.31`, Karpenter chart `1.0.8`, AL2023 AMI alias, bitnami/etcd tag.
5. **Security**: set `cluster_endpoint_public_access_cidrs` in `terraform/main/dev.tfvars`
   (now honored) to your egress CIDR.
6. **Prereqs on your machine**: `terraform >= 1.10`, `envsubst` (gettext), `aws`/`kubectl`/`helm`.
   The system node group is **3× m7i.large** (etcd HA).

## Known limitations

- Never deployed; all upstream Dynamo specifics are best-effort and `# VERIFY`-tagged.
- Trace→logs correlation (Tempo→Loki `service_name`) is PLAUSIBLE-only until verified live.
- The chaos annotation bridge installs its Python deps at pod start (no custom image); fine for
  a lab, bake an image if you want it hardened.
