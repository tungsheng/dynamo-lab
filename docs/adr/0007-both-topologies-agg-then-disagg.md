# Support both topologies; aggregated for bring-up, disaggregated as the headline

Topology is a selectable profile (`fleet/agg.yaml` and `fleet/disagg.yaml`). The lab defaults
to aggregated for scaffolding and bring-up, and runs its headline experiments on
disaggregated.

## Why

Disaggregated serving (separate prefill/decode pools exchanging KV cache) is Dynamo's
signature and the richer thing to observe — prefill and decode scale independently under a
spike, and "kill a prefill worker" vs "kill a decode worker" are genuinely different failure
stories. But it adds bring-up complexity, so we prove the scaffolding on the simple
aggregated profile first. The mocker supports both, so carrying two profiles is cheap.

## Consequences

- Two DGD variants to keep in sync.
- Rejected: **aggregated only** (simplest, least to observe), **disaggregated only** (more
  moving parts during initial bring-up).
