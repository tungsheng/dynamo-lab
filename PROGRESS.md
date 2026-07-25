# Progress

_Last updated: 2026-07-25_

Build/status log for the Dynamo Lab. See [README.md](README.md) for usage,
[CONTEXT.md](CONTEXT.md) for vocabulary, and [docs/adr/](docs/adr/) for the design decisions.

## Milestones

- [x] **Design grilling** — 12 architectural decisions locked (ADR 0001–0008).
- [x] **Scaffold generated** — Terraform, platform Helm values, fleet CRDs, chaos, load, and
  the make/scripts glue.
- [x] **Verification pass 1** (consistency + correctness) — 1 blocker + 7 major + 6 minor fixed.
- [x] **Cleanup/audit pass 2** (5 lenses + adversarial verify) — 25 confirmed findings fixed,
  2 false positives rejected.
- [ ] **First `make up` against AWS** — NOT yet run. Nothing has been applied to a real account.
- [ ] **Resolve `# VERIFY` markers** against a pinned Dynamo release (see below).
- [ ] **First end-to-end experiment** — spike + chaos on the disaggregated fleet.

## What's built

A declarative, GPU-free Dynamo fleet on EKS with full observability, Chaos Mesh fault
injection, and k6 spike load — driven by `make up/down/pause/resume`, `fleet-up`,
`chaos-start/stop`, `load-start/stop`. Architecture and layout are in the README.

## Audit history

**Pass 1 — consistency + correctness** (2 verifier agents). Caught the cross-file seams a
parallel build leaves: scripts pointing at wrong Helm values paths, dashboards/chaos-bridge
never applied, `PROFILE` not switchable, k6 targeting a non-existent frontend service, S3
locking not enabled, Karpenter installed twice. All fixed.

**Pass 2 — 5-lens cleanup/audit** (shell · terraform · k8s · wiring · simplify, then a
consolidating adversarial verifier). 25 confirmed, 2 rejected. Highlights:

- **Blocker:** `platform.sh` referenced a non-existent `values.yaml` for Chaos Mesh — would
  abort `make up`. Fixed + `values_args` now fails loudly instead of silently dropping.
- Decoupled the two independently-versioned Dynamo charts (`DYNAMO_CRDS_VERSION` /
  `DYNAMO_PLATFORM_VERSION`) from the mocker image tag.
- `render()` now dies loudly if `envsubst` is missing (was silently `cat`-ing, which would
  apply manifests with literal `${VAR}` placeholders).
- **k6 token collision (subtle):** the embedded k6 JS uses `${PROFILE}`/`${FRONTEND_URL}`/
  `${MODEL}` as JS template literals, which `envsubst` was rewriting at render time. Fixed by
  giving the container env block distinct `${K6_PROFILE}`/`${K6_FRONTEND_URL}` render tokens
  and dropping `PROFILE`/`FRONTEND_URL`/`MODEL` from `RENDER_VARS`. Verified via a real
  `envsubst` render: env values inject correctly while the JS literals survive untouched.
- Terraform: version floor bumped to `>= 1.10.0` (native S3 locking), public/private subnet
  CIDR overlap fixed for 4-AZ regions, dead `tls`/`null` providers removed.
- Shipped an explicit `podmonitor-fleet.yaml` so fleet metrics don't depend on an unverified
  operator behavior; fixed several docs that contradicted the implementation.

## Outstanding — before the first `make up`

The scaffold has **never been applied to AWS**. Resolve these `# VERIFY:` markers
(`grep -rn VERIFY .`) against the Dynamo release you pin:

1. **Versions**: pin `DYNAMO_VERSION` (mocker image) + `DYNAMO_CRDS_VERSION` /
   `DYNAMO_PLATFORM_VERSION` (operator charts) to real, existing versions; confirm the mocker
   image runs CPU-only.
2. **Fleet schema**: `DynamoGraphDeployment` fields + the synthesized planner `--config`
   (`fleet/*.yaml`) — a wrong planner config crash-loops the pod rather than failing safe.
3. **Metrics**: `podmonitor-fleet.yaml`'s selector label (`nvidia.com/dynamo-component-type`)
   and component metrics port (`8081`) match what the operator actually sets.
4. **Frontend Service name** (`<dgd>-frontend`) that k6 targets.
5. **Chaos selectors** (`nvidia.com/dynamo-component-type`) actually select fleet pods.
6. **Infra versions**: EKS `1.31`, Karpenter chart `1.0.8`, AL2023 AMI alias, bitnami/etcd tag.
7. **Security**: tighten `cluster_endpoint_public_access_cidrs` from `0.0.0.0/0`.
8. **Prereqs on your machine**: `terraform >= 1.10`, `envsubst` (gettext), `aws`/`kubectl`/`helm`.

## Known limitations

- Never deployed; all upstream Dynamo specifics are best-effort and `# VERIFY`-tagged.
- Trace→logs correlation (Tempo→Loki `service_name`) is PLAUSIBLE-only until verified live.
- The chaos annotation bridge installs its Python deps at pod start (no custom image);
  fine for a lab, bake an image if you want it hardened.
