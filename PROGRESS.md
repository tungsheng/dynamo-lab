# Progress

_Last updated: 2026-07-28_

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
- [x] **Platform version hardening (Pass 6)** — bumped the observability/coordination/chaos chart
  pins to latest (kube-prometheus-stack 87, Loki 7, NATS 2, Tempo, promtail, chaos-mesh 2.8); held
  bitnami/etcd 10.7.1 with a verified `bitnamilegacy` image; all render-verified vs K8s 1.36 (PR #9).
- [x] **First `make up` against AWS — DONE & LIVE-VALIDATED (2026-07-28).** Full bring-up on
  **EKS 1.36**: bootstrap → infra (VPC / EKS / Karpenter) → platform (coordination, operator,
  observability, chaos-mesh) → fleet. Surfaced **5 live-only bugs**, all fixed (Pass 7 below).
- [x] **First end-to-end experiment (partial).** k6 **spike** ramped to 300 VUs on the agg fleet —
  7,596 iterations, **0 errors**, worker stable (experiment C). **Disaggregated** fleet validated
  end-to-end (frontend + prefill + decode + planner all Ready, `/health` 200) with the **planner
  autoscaling loop running live** (experiment B). Karpenter scaled worker nodes on demand (ADR 0008).
- [ ] **Chaos experiment** — Chaos Mesh fault injection against the live fleet (experiment A) — not
  yet exercised.
- [ ] **Resolve remaining `# VERIFY` markers** (observability / coordination / chaos / load /
  scripts). Terraform/infra fully resolved; the fleet layer is now **live-validated**.
- [ ] **Track G — Grove gang-scheduling (GPU-free), additive.** New optional track (ADR
  [0009](docs/adr/0009-track-g-grove-gang-scheduling.md)) to observe Dynamo's Grove gang
  scheduling, multi-level autoscaling, and topology-aware placement with the mocker — no GPUs,
  no change to the A/B/C roadmap or the default `make up`. **Static build COMPLETE** (items 1–7):
  ADR, `platform/grove/` scaffolding, install wiring (`GROVE=1`), the `grove-scale` fleet overlay,
  `make track-g-up`/`track-g-down`, observability (PodMonitor + dashboard), and `CONTEXT.md` vocab
  all landed + lint-clean. Only **live validation** remains (render on 1.36, the queue name, watch
  a gang reconcile) — best folded into the experiment-A session. (Track N / NIXL deferred — GPUs.)

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

**Pass 6 — platform chart-version hardening** (render-verified; PR #9). Bumped the
observability/coordination/chaos Helm pins and render-verified each with `helm template` against
K8s 1.36 using the lab's own values: kube-prometheus-stack 66→87, grafana/loki 6→7, nats/nats 1→2,
tempo 1.14→1.24, promtail 6.16→6.17, chaos-mesh 2.6→2.8. Held bitnami/etcd at 10.7.1 (newer charts
pin an etcd tag absent from the frozen `bitnamilegacy` archive) and verified the pinned
`bitnamilegacy/etcd:3.5.21-debian-12-r5` image is present + anonymously pullable.

**Pass 7 — first live `make up` on EKS 1.36 + the 5 bugs it surfaced** (2026-07-28; PR #10 + a
disagg follow-up). The full bring-up ran end to end and is live-validated. Five **live-only** bugs
(none catchable by static / `terraform plan` / `helm template` checks) were found and fixed:

- **Kubelet-rejected node label (live-proven).** `app.kubernetes.io/part-of` is in the kubernetes.io
  namespace, which kubelet refuses via `--node-labels` — the kubelet crash-looped on flag validation
  and nodes never joined (`NodeCreationFailure`). A ~2-hour node-join hunt traced to this; it was NOT
  the EKS version or the endpoint lockdown (a downgrade would have failed identically). Removed from
  both node-label sites (system node group + Karpenter NodePool); kept `dynamo-lab/node-pool`.
  Root-caused by reading the failing kubelet journal on a probe node via SSM.
- **PodMonitor CRD ordering (live-proven).** `platform.sh` installed etcd/NATS (which create
  PodMonitors) before kube-prometheus-stack installs the PodMonitor CRD. Reordered — observability
  first.
- **Fleet probe port name (live-validated).** The operator adds a `httpGet /live port=system`
  startup probe to worker/planner, but manifests named the `DYN_SYSTEM_PORT` port `metrics` →
  `strconv.Atoi: parsing "system"` → pods never Ready. Named the port `system`; PodMonitor scrapes
  both `system` + `metrics`. Confirmed on agg + disagg workers.
- **Planner ⇢ aggregated incompatibility (live-validated).** The planner's KubernetesConnector
  requires `prefill`+`decode` components, so it crash-loops in the aggregated topology. Removed the
  planner from `agg.yaml` (it belongs in disagg, ADR 0007); agg DGD now reconciles to READY.
- **Disagg planner GPU-count config (live-validated).** Found while validating disagg: the planner's
  budget init requires `prefill_engine_num_gpu` / `decode_engine_num_gpu`. Added nominal `1` each
  (mocker) → the planner starts and runs its load-scaling loop.

The endpoint-allowlist experiment tried while chasing bug 1 is reverted — worker nodes reach the API
via the **private** endpoint (node DNS resolves to the private ENIs; `/healthz` 200). Minor open
item: components log an OTEL *log*-export error to `127.0.0.1:4317` (the OTLP-logs exporter default;
the lab ships logs via JSONL→promtail→Loki, so it's cosmetic — traces use the configured Tempo
endpoint).

**Teardown hardening.** The first `make down` destroyed all 91 resources cleanly but left **3
orphaned EBS volumes** in `available` state (the Prometheus / etcd-1 / nats-1 PVCs): `down.sh`
deleted the PVCs but did not wait for ebs-csi to release the volumes before `terraform destroy` tore
the driver down, so they leaked — a billing tail that defeats "$0 idle". Hardened `down.sh`: it now
waits up to 4m for the CSI driver to release cluster-tagged volumes before destroy, then sweeps +
deletes any that survive afterward. Re-verified `$0` idle (no EKS / EC2 / NAT / EBS remain; the
bootstrap state bucket is intentionally retained).

## Outstanding — after the first live `make up`

Applied and **live-validated on EKS 1.36** (2026-07-28, Pass 7). The whole `make up` path works
end-to-end; what remains:

1. **Platform chart versions — DONE (Pass 6).** All observability/coordination/chaos chart pins
   bumped + render-verified; bitnami/etcd held at 10.7.1 with a verified `bitnamilegacy` image.
2. **Live-only fleet checks — largely DONE (Pass 7).** Fleet component-type labels, the fixed
   probe/port wiring, and the PodMonitor scrape are confirmed live on agg + disagg. Still to
   exercise: the **chaos** selectors + annotation bridge against the live fleet (experiment A), and
   the **v1alpha1 → v1beta1** DGD apiVersion bump (the operator logs a deprecation warning on apply).
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

## Track G — Grove gang-scheduling (GPU-free, additive)

A new **optional track** that observes Dynamo's [Grove](https://github.com/ai-dynamo/grove)
orchestration layer — gang scheduling, hierarchical (multi-level) autoscaling of the
prefill+decode unit, topology-aware placement, custom startup ordering — with the existing
**mocker** fleet. Grove is a *control-plane* concern, so it needs **no GPUs**: the mocker runs
Dynamo's real operator/planner paths while simulating compute. Gated behind its own switch; the
default `make up`/`down` and the A/B/C experiments are unchanged. Rationale + non-goals in ADR
[0009](docs/adr/0009-track-g-grove-gang-scheduling.md).

**Non-goal (deferred): Track N / NIXL.** The NIXL KV-transfer data plane only moves real KV
tensors, which the mocker never produces — a meaningful test needs real GPUs (+ RDMA/EFA), a
real-cost experiment that breaks `$0` idle. It gets its own ADR + GPU node class if pursued.

**Work items** (the change surface; additive — nothing here reorders the roadmap above):

1. [x] **`platform/grove/` scaffolding + upstream pins RESOLVED.** `platform/grove/` README +
   `values-grove-operator.yaml` + `values-kai-scheduler.yaml`, yamllint clean. Pinned against
   the Dynamo v1.3.0 compat matrix from primary sources: **Grove `v0.1.0-alpha.11`**
   (`oci://ghcr.io/ai-dynamo/grove/grove-charts`), **KAI `v0.15.2`**
   (`oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler`; ≥0.13.4 for 1.3.x, ≥0.15.2 for
   topology-aware). API surface confirmed: `PodCliqueSet`/`PodClique`/`PodCliqueScalingGroup`
   (`grove.io/v1alpha1`) — *PodGangSet is renamed*. Enablement confirmed: operator
   `global.grove.enabled` + `global.kai-scheduler.enabled`, Grove-by-default (opt out with
   annotation `nvidia.com/enable-grove: "false"`). Only *live* `# VERIFY:`s remain (render on
   K8s 1.36; the queue-name gotcha below).
2. [x] **`platform.sh` wiring** — optional `install_grove()` gated behind `GROVE=1` (default off)
   that installs the two OCI charts **and** sets `global.grove.enabled=true` +
   `global.kai-scheduler.enabled=true` on the `dynamo-platform` release, so the default bring-up
   is untouched. *(done — `install_grove`/`grove_operator_flags`/`grove_down` in `platform.sh`,
   `NS_`/`REL_` vars in `common.sh`; verified `GROVE=0` → 0 extra operator flags; shellcheck clean.)*
3. [x] **`fleet/grove-scale.yaml`** — reuse `disagg.yaml` **as-is** (the operator generates the
   PodCliqueSet/PodClique/`PodCliqueScalingGroup` from it once Grove is on) with high replica
   knobs to create gang-scheduling pressure, **and resolve the queue-name gotcha**. *(done —
   `mocker-grove` DGD, only 3 deltas vs `disagg.yaml`: name/label, the two Grove annotations
   with `nvidia.com/kai-scheduler-queue: default-queue` (option b), and prefill/decode replicas
   1→3. `fleet.sh` gains the `grove-scale` profile; yamllint + envsubst-render clean.)*
4. [x] **`make track-g-up` / `track-g-down`** — install Grove + apply the overlay as one step,
   kept separate from `fleet-up PROFILE=…`. *(done — Makefile targets + `platform.sh`
   `grove-up`/`grove-down` actions for an already-running cluster; `make -n` verified.)*
5. [x] **Observability** — a PodMonitor + a Grafana dashboard for KAI-Scheduler / PodGang state
   (scheduled vs gang-blocked `Pending`), so gang formation is watchable next to the fleet.
   *(done — `platform/grove/podmonitor-grove.yaml` + `grafana-grove-dashboard-configmap.yaml`,
   applied by `install_grove()`. Core panels use kube-state-metrics filtered to `mocker-grove.*`
   (gang-blocked/running + node count for multi-level autoscaling) so they work immediately;
   PodMonitor selectors/ports + the scheduler-internals panel are `# VERIFY:`-marked. Dashboard
   JSON validated; `${datasource}` survives envsubst; yamllint + shellcheck clean.)*
6. [x] **`CONTEXT.md` vocabulary** — Grove, PodGang / gang scheduling, Track G / Track N.
   *(done — added the four terms with `_Avoid_` notes matching the CONTEXT.md style.)*
7. [x] **ADR 0009** — decision, GPU-free rationale, Track N deferral. *(done)*

## Known limitations

- Deployed + validated on EKS 1.36 (agg + disagg fleets serve; planner autoscaling loop runs; k6
  spike to 300 VUs with 0 errors). Chaos (experiment A) is the one headline experiment not yet run.
- Trace→logs correlation (Tempo→Loki `service_name`) is PLAUSIBLE-only until verified live; note the
  OTLP-logs exporter also logs a cosmetic `127.0.0.1:4317` connection error (logs ship via promtail).
- The chaos annotation bridge installs its Python deps at pod start (no custom image); fine for
  a lab, bake an image if you want it hardened.
