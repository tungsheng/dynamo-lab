// load/k6/script.js
//
// dynamo-lab load generator. Drives the OpenAI-compatible Dynamo frontend at
//   ${FRONTEND_URL}/v1/chat/completions
// with the traffic shape named by ${PROFILE} (see ../profiles/profiles.js).
//
// Run locally:
//   FRONTEND_URL=http://localhost:8000 PROFILE=spike \
//     k6 run load/k6/script.js
//
// Run locally with results pushed to Prometheus remote-write:
//   K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
//   FRONTEND_URL=http://localhost:8000 PROFILE=spike \
//     k6 run -o experimental-prometheus-rw load/k6/script.js
//
// In-cluster: see ../k6-job.yaml (mounts this file from a ConfigMap).

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { profiles, thresholds, profileNames } from '../profiles/profiles.js';

// ---------------------------------------------------------------------------
// Configuration from environment
// ---------------------------------------------------------------------------
const FRONTEND_URL = (__ENV.FRONTEND_URL || 'http://localhost:8000').replace(/\/+$/, '');
const PROFILE = __ENV.PROFILE || 'spike';
const MODEL = __ENV.MODEL || 'Qwen/Qwen3-0.6B';
const MAX_TOKENS = Number(__ENV.MAX_TOKENS || 64);
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '60s';
const STREAM = (__ENV.STREAM || 'false').toLowerCase() === 'true';

if (!profiles[PROFILE]) {
  throw new Error(
    `Unknown PROFILE="${PROFILE}". Valid profiles: ${profileNames().join(', ')}`
  );
}

// ---------------------------------------------------------------------------
// Custom metrics (surface as k6_* series in Prometheus remote-write)
// ---------------------------------------------------------------------------
const chatErrors = new Counter('dynamo_chat_errors');
const promptTokens = new Trend('dynamo_prompt_tokens');
const completionTokens = new Trend('dynamo_completion_tokens');

// ---------------------------------------------------------------------------
// k6 options — one active scenario, chosen by PROFILE
// ---------------------------------------------------------------------------
export const options = {
  // Tag every metric with the profile so dashboards can slice by traffic shape.
  tags: { profile: PROFILE },
  scenarios: {
    [PROFILE]: profiles[PROFILE],
  },
  thresholds: thresholds[PROFILE] || {},
  // Keep the client honest about DNS/redirects in-cluster.
  noConnectionReuse: false,
  discardResponseBodies: false,
};

// A tiny rotating set of prompts so KV-aware routing sees some cache locality
// AND some novelty (mix of repeated and unique-ish prompts).
const PROMPTS = [
  'In one sentence, what is a large language model?',
  'Give me three uses for a paperclip.',
  'Summarize the plot of Hamlet in two sentences.',
  'What is the capital of Australia?',
  'Write a haiku about distributed systems.',
  'Explain KV cache to a five year old.',
  'List two benefits of disaggregated inference.',
  'Translate "good morning" into French and Japanese.',
];

function buildBody() {
  const prompt = PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
  return JSON.stringify({
    model: MODEL,
    messages: [
      { role: 'system', content: 'You are a concise assistant.' },
      { role: 'user', content: prompt },
    ],
    max_tokens: MAX_TOKENS,
    temperature: 0.7,
    stream: STREAM,
  });
}

const params = {
  headers: { 'Content-Type': 'application/json' },
  timeout: REQUEST_TIMEOUT,
  tags: { endpoint: 'chat_completions' },
};

// ---------------------------------------------------------------------------
// The iteration: one chat-completions request.
// ---------------------------------------------------------------------------
export default function () {
  const res = http.post(`${FRONTEND_URL}/v1/chat/completions`, buildBody(), params);

  const ok = check(res, {
    'status is 2xx': (r) => r.status >= 200 && r.status < 300,
    'has choices': (r) => {
      if (STREAM) return true; // streamed SSE body isn't JSON-parsed here
      try {
        const j = r.json();
        return j && Array.isArray(j.choices) && j.choices.length > 0;
      } catch (_e) {
        return false;
      }
    },
  });

  if (!ok) {
    chatErrors.add(1);
    return;
  }

  // Record token usage when the frontend returns it (non-streaming path).
  if (!STREAM) {
    try {
      const usage = res.json('usage');
      if (usage) {
        if (typeof usage.prompt_tokens === 'number') promptTokens.add(usage.prompt_tokens);
        if (typeof usage.completion_tokens === 'number') {
          completionTokens.add(usage.completion_tokens);
        }
      }
    } catch (_e) {
      // usage is optional; ignore parse issues.
    }
  }
}

// ---------------------------------------------------------------------------
// End-of-run banner (stdout). Prometheus remote-write carries the real data;
// this is just a human-readable confirmation of what shape ran.
// ---------------------------------------------------------------------------
export function handleSummary(data) {
  const line = (k) => {
    const m = data.metrics[k];
    return m ? JSON.stringify(m.values) : '(n/a)';
  };
  const banner =
    `\n=== dynamo-lab load: profile="${PROFILE}" target=${FRONTEND_URL} model=${MODEL} ===\n` +
    `http_reqs:          ${line('http_reqs')}\n` +
    `http_req_failed:    ${line('http_req_failed')}\n` +
    `http_req_duration:  ${line('http_req_duration')}\n` +
    `dynamo_chat_errors: ${line('dynamo_chat_errors')}\n`;
  return {
    stdout: banner,
  };
}
