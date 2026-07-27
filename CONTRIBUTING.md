# Contributing to Dynamo Lab

Thanks for your interest. This is a GPU-free lab for watching an NVIDIA Dynamo
inference **fleet** recover from failure, autoscale, and absorb traffic spikes on
Amazon EKS. Please read [`CONTEXT.md`](CONTEXT.md) for the project vocabulary and
[`docs/adr/`](docs/adr/) for why each design choice was made before proposing a change.

## Ground rules

- **Language matters.** Use the exact terms defined in [`CONTEXT.md`](CONTEXT.md)
  (fleet, mocker worker, coordination plane, load profile, chaos experiment, the
  lifecycle verbs). Consistent naming is a first-class concern here.
- **Decisions live in ADRs.** A change that reverses or extends an architectural
  decision should add or amend an ADR under [`docs/adr/`](docs/adr/), not just the code.
- **Nothing has been applied to AWS yet.** Upstream Dynamo specifics are best-effort
  and tagged `# VERIFY:`. If you validate one against a real release, remove the marker
  and note the version you verified against. See the checklist in
  [`PROGRESS.md`](PROGRESS.md).

## Local checks (mirror CI)

CI runs three static linters — no AWS calls. Reproduce them before opening a PR:

```bash
# Shell glue
shellcheck --severity=warning scripts/*.sh scripts/lib/*.sh

# Kubernetes manifests + Helm values (pip install yamllint)
yamllint -c .yamllint.yml .

# Terraform (both modules)
for m in terraform/bootstrap terraform/main; do
  terraform -chdir="$m" fmt -check -recursive
  terraform -chdir="$m" init -backend=false -input=false
  terraform -chdir="$m" validate
done
```

Run `terraform fmt -recursive` to auto-fix formatting. If you change provider or
module versions, regenerate the committed lock files:

```bash
terraform -chdir=terraform/main providers lock \
  -platform=linux_amd64 -platform=darwin_arm64
```

## Commit and PR conventions

- Keep commits focused; write imperative subject lines (e.g. "Fix etcd anti-affinity").
- Reference the ADR or `# VERIFY:` marker a change relates to.
- The PR template asks what you changed, how you verified it, and what a reviewer
  should watch for. A green CI run is expected before review.

## What to work on

The highest-value work right now is resolving the `# VERIFY:` markers against a pinned
Dynamo release (`grep -rn VERIFY .`) so the lab can survive its first `make up`. The
"Resolve a `# VERIFY:` marker" issue template is built for exactly this.

## Reporting problems

Open an issue using one of the templates. For a suspected bug, include what you ran,
what happened, and the relevant `make` target or manifest. This project has never been
deployed, so "it doesn't apply cleanly" reports are genuinely useful.
