// load/profiles/profiles.js
//
// The five named load profiles for dynamo-lab. Each entry is a k6 *scenario*
// (an executor config) that shapes traffic against the Dynamo frontend.
// script.js reads PROFILE from the environment and installs exactly one of
// these as the active scenario.
//
// All arrival-rate executors count *iterations* (one iteration == one
// /v1/chat/completions request, see ../k6/script.js), so `rate` is
// requests-per-`timeUnit`.
//
// Tuning knobs (env overrides, all optional):
//   BASE_RPS   baseline requests/sec           (default 5)
//   PEAK_RPS   peak requests/sec for ramp/spike/sustained (default 250)
//   SOAK_RPS   moderate requests/sec for soak  (default 20)
//   VUS_MAX    ceiling of preallocated+max VUs  (default 300)
// Durations are likewise overridable per profile below.
//
// Design notes:
//  - Arrival-rate executors (not VU-count executors) are used everywhere so
//    that a slow/failing fleet does NOT throttle the offered load — k6 keeps
//    trying to hit the target rate and surfaces the backpressure as errors and
//    dropped iterations, which is exactly the signal the spike experiment wants.
//  - spike is the headline shape: hold baseline, jump ~50x almost instantly,
//    hold the burst, then collapse back to baseline to watch recovery.

const num = (name, dflt) => {
  const v = __ENV[name];
  const n = v === undefined || v === '' ? NaN : Number(v);
  return Number.isFinite(n) ? n : dflt;
};
const str = (name, dflt) => {
  const v = __ENV[name];
  return v === undefined || v === '' ? dflt : v;
};

const BASE_RPS = num('BASE_RPS', 5);
const PEAK_RPS = num('PEAK_RPS', 250);
const SOAK_RPS = num('SOAK_RPS', 20);
const VUS_MAX = num('VUS_MAX', 300);

// Preallocated VUs govern how much concurrency k6 can muster to sustain the
// arrival rate. Rough rule: preallocate ~ target_rps * expected_latency_s.
const preVUs = Math.max(20, Math.min(VUS_MAX, Math.ceil(PEAK_RPS * 0.5)));

const common = {
  timeUnit: '1s',
  preAllocatedVUs: preVUs,
  maxVUs: VUS_MAX,
};

export const profiles = {
  // Constant low background traffic. The "is anything on fire?" idle load.
  baseline: {
    executor: 'constant-arrival-rate',
    rate: BASE_RPS,
    duration: str('BASELINE_DURATION', '10m'),
    ...common,
  },

  // Smooth linear ramp from baseline up to peak and back down — reveals the
  // knee where the planner starts adding workers and Karpenter adds nodes.
  ramp: {
    executor: 'ramping-arrival-rate',
    startRate: BASE_RPS,
    stages: [
      { target: BASE_RPS, duration: str('RAMP_WARMUP', '1m') },
      { target: PEAK_RPS, duration: str('RAMP_UP', '5m') },
      { target: PEAK_RPS, duration: str('RAMP_HOLD', '3m') },
      { target: BASE_RPS, duration: str('RAMP_DOWN', '3m') },
    ],
    ...common,
  },

  // The spike: baseline -> near-instant ~50x burst -> hold -> collapse back.
  // The 5s ramp edges are intentional (a literal 0s step can drop iterations
  // on scheduler granularity); it is still effectively a step change.
  spike: {
    executor: 'ramping-arrival-rate',
    startRate: BASE_RPS,
    stages: [
      { target: BASE_RPS, duration: str('SPIKE_PRE', '2m') },   // settle at baseline
      { target: PEAK_RPS, duration: '5s' },                     // sudden burst up (~50x)
      { target: PEAK_RPS, duration: str('SPIKE_HOLD', '2m') },  // hold the flood
      { target: BASE_RPS, duration: '5s' },                     // sudden recovery down
      { target: BASE_RPS, duration: str('SPIKE_POST', '3m') },  // watch recovery
    ],
    ...common,
  },

  // Constant high pressure — steady-state saturation, not a transient.
  sustained: {
    executor: 'constant-arrival-rate',
    rate: PEAK_RPS,
    duration: str('SUSTAINED_DURATION', '15m'),
    ...common,
  },

  // Moderate load held for a long time — leak/drift/stability soak.
  soak: {
    executor: 'constant-arrival-rate',
    rate: SOAK_RPS,
    duration: str('SOAK_DURATION', '2h'),
    ...common,
  },
};

// Per-profile pass/fail thresholds. Kept lenient because a failing fleet under
// chaos is an expected observation, not a test failure — these exist mainly so
// the summary prints useful percentiles, not to gate CI.
export const thresholds = {
  baseline: {
    http_req_failed: ['rate<0.02'],
    http_req_duration: ['p(95)<2000'],
  },
  ramp: {
    http_req_failed: ['rate<0.10'],
    http_req_duration: ['p(95)<5000'],
  },
  spike: {
    // No hard gate: the burst is *meant* to overload the fleet.
    http_req_failed: ['rate<0.50'],
  },
  sustained: {
    http_req_failed: ['rate<0.20'],
    http_req_duration: ['p(95)<8000'],
  },
  soak: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<3000'],
  },
};

export function profileNames() {
  return Object.keys(profiles);
}
