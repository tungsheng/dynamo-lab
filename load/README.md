# load — k6 traffic profiles

Programmable traffic against the Dynamo **frontend** (OpenAI-compatible API), used
for experiment **(C) traffic-spike behavior** and to drive load for **(B) planner
autoscaling**. Results are pushed to Prometheus via remote-write, so client-side
latency/error series land on the same Grafana stack as the fleet's own metrics.

```
load/
├── k6/script.js          # the k6 script: hits /v1/chat/completions, picks a profile
├── profiles/profiles.js  # the 5 named profiles (executors) + thresholds
├── k6-job.yaml           # in-cluster Job (ns load) + ConfigMap (embeds the two .js)
└── README.md             # this file
```

## The five profiles

Each profile is a k6 *scenario* (an executor configuration). All use **arrival-rate**
executors so a slow/overloaded fleet does **not** throttle the offered load — k6 keeps
trying to hit the target rate and surfaces the backpressure as errors/dropped
iterations, which is the signal we want.

| Profile     | Executor                 | Shape                                                        | Default duration |
|-------------|--------------------------|-------------------------------------------------------------|------------------|
| `baseline`  | `constant-arrival-rate`  | Steady low background (`BASE_RPS`, default 5 rps)            | ~10m             |
| `ramp`      | `ramping-arrival-rate`   | Linear climb baseline → peak → back down                    | ~12m             |
| `spike`     | `ramping-arrival-rate`   | Hold baseline → **near-instant ~50× burst** → hold → recover | ~7m             |
| `sustained` | `constant-arrival-rate`  | Constant high pressure (`PEAK_RPS`, default 250 rps)        | ~15m             |
| `soak`      | `constant-arrival-rate`  | Moderate load held a long time (`SOAK_RPS`, default 20 rps) | ~2h              |

`spike` is the headline shape: `BASE_RPS` → `PEAK_RPS` is ~50× at the defaults
(5 → 250 rps), stepped in 5 s so it reads as an instantaneous jump. Watch the planner
add mocker workers and Karpenter add nodes on the way up, and both drain on the way down.

### Tuning knobs (env vars, all optional)

| Var                | Default | Applies to               |
|--------------------|---------|--------------------------|
| `BASE_RPS`         | `5`     | baseline / ramp / spike floor |
| `PEAK_RPS`         | `250`   | ramp / spike / sustained peak |
| `SOAK_RPS`         | `20`    | soak                     |
| `VUS_MAX`          | `300`   | max concurrent VUs ceiling |
| `MAX_TOKENS`       | `64`    | completion length per request |
| `STREAM`           | `false` | SSE streaming vs. buffered |
| `*_DURATION`, `SPIKE_HOLD`, `RAMP_UP`, … | see `profiles/profiles.js` | per-stage durations |

## Run in-cluster (the Job)

The Job runs the `grafana/k6` image with the script mounted from a ConfigMap, and
pushes to the in-cluster Prometheus remote-write receiver
(`kube-prometheus-stack-prometheus.monitoring:9090/api/v1/write`).

Via make (owns PROFILE / FRONTEND_URL wiring):

```bash
make load-start PROFILE=spike     # baseline | ramp | spike | sustained | soak
make load-stop
```

Directly with kubectl (self-contained — the ConfigMap is embedded):

```bash
kubectl apply -f load/k6-job.yaml
kubectl -n load logs -f job/k6-load
kubectl -n load delete job k6-load        # stop / clean up
```

Point it at a different fleet / profile by patching env before apply, e.g.:

```bash
PROFILE=sustained \
FRONTEND_URL=http://mocker-disagg-frontend.dynamo.svc.cluster.local:8000 \
  yq -i '(.spec.template.spec.containers[0].env[] | select(.name=="PROFILE")).value = strenv(PROFILE)
        | (.spec.template.spec.containers[0].env[] | select(.name=="FRONTEND_URL")).value = strenv(FRONTEND_URL)' \
  load/k6-job.yaml && kubectl apply -f load/k6-job.yaml
```

> The ConfigMap in `k6-job.yaml` embeds copies of both `.js` files so a plain
> `kubectl apply` works, and `scripts/load.sh` applies this self-contained Job
> directly. If you edit the `.js` by hand, keep the embedded copies in
> `k6-job.yaml` in sync.

## Run locally (k6 on your laptop)

Port-forward the frontend, then run the same script:

```bash
kubectl -n dynamo port-forward svc/mocker-agg-frontend 8000:8000 &

FRONTEND_URL=http://localhost:8000 PROFILE=spike \
  k6 run load/k6/script.js
```

With remote-write to a port-forwarded Prometheus:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
K6_PROMETHEUS_RW_TREND_STATS='p(50),p(90),p(95),p(99),min,max,avg' \
FRONTEND_URL=http://localhost:8000 PROFILE=ramp \
  k6 run -o experimental-prometheus-rw load/k6/script.js
```

Smoke-test a single profile fast:

```bash
BASE_RPS=1 PEAK_RPS=5 SPIKE_HOLD=15s SPIKE_PRE=10s SPIKE_POST=10s \
FRONTEND_URL=http://localhost:8000 PROFILE=spike \
  k6 run load/k6/script.js
```

## Where the data shows up

- **Client view** (k6): `k6_http_reqs_total`, `k6_http_req_duration_*`,
  `k6_http_req_failed_*`, plus custom `k6_dynamo_chat_errors_total`,
  `k6_dynamo_prompt_tokens`, `k6_dynamo_completion_tokens`. All tagged
  `profile="<name>"` and `endpoint="chat_completions"`.
- **Server view** (authoritative for LLM-serving latency — TTFT / ITL / goodput):
  Dynamo's own frontend metrics, per ADR 0005. Prefer these over k6's client-side
  timings for serving analysis; k6 is the *offered-load* and *client-error* view.
