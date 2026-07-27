<!-- Thanks for contributing to Dynamo Lab. Keep PRs focused. -->

## What & why

<!-- What does this change, and what problem does it solve? Link the ADR or
     `# VERIFY:` marker it relates to, if any. -->

## Type of change

- [ ] Fixes a `# VERIFY:` marker against a pinned Dynamo release
- [ ] Fleet / platform / chaos / load manifest change
- [ ] Terraform (infra) change
- [ ] Scripts / Makefile glue
- [ ] Docs / ADR
- [ ] Other

## How I verified

<!-- The lab has never been applied to AWS. Say exactly how far you took this:
     lint-only, `terraform plan`, a real `make up`, a live experiment, etc. -->

- [ ] `shellcheck --severity=warning scripts/*.sh scripts/lib/*.sh`
- [ ] `yamllint -c .yamllint.yml .`
- [ ] `terraform fmt -check` + `validate` (both modules)
- [ ] Applied against a real AWS account (describe below)

## Reviewer notes

<!-- Anything to watch for: a `# VERIFY:` assumption still unverified, a cost
     implication, a decision that touches an ADR. -->
