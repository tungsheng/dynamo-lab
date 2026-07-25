# k6 as the load generator

Goal (C) is observing behaviour under traffic spikes, so we need programmable spike shapes
against the OpenAI-compatible frontend. We use Grafana **k6** with named profiles, over
Locust or Dynamo's own AIPerf.

## Why

k6's `ramping-arrival-rate` executor gives precise control over the exact spike shape
(hold baseline → sudden Nx burst → recover), which *is* the experiment, and it has native
Prometheus remote-write so load lands on the same Grafana stack as everything else.

## Consequences

- k6 provides the client-side view; LLM-serving latency (TTFT / ITL / goodput) comes from
  Dynamo's own frontend metrics rather than k6.
- Dynamo's **AIPerf** is retained as an optional "realistic benchmark" mode, not the primary
  spike driver.
- Rejected: **Locust** (great ergonomics, less precise arrival-rate control), **AIPerf as
  primary** (a benchmark tool, not built for scripted spike profiles).
