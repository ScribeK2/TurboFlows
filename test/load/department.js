/**
 * TurboFlows department load test — the launch gate agreed in the 2026-09-14
 * grilling session (Q20, Q24, Q25). Run it against the production replica
 * (test/load/replica/README.md), never against production:
 *
 *   docker run --rm --network host -v "$PWD/test/load:/scripts:ro" -v "$PWD/tmp/load-results:/results" \
 *     -e SANDBOX_WORKFLOW_ID=... -e SANDBOX_STEP_IDS=... \
 *     grafana/k6 run --insecure-skip-tls-verify --summary-export /results/summary.json \
 *     --console-output /results/console.log /scripts/department.js
 *
 * Four scenarios run together:
 *   csr_runs     CSRs working calls: sign in, idle on home between calls (with
 *                the session heartbeat), start a workflow, answer every 10–20 s,
 *                10% close the tab mid-run, 5% go Back once
 *   signin_rush  50 people signing in for the first time within 5 minutes and
 *                joining a group on /welcome
 *   managers     12 managers reading Analytics and their team page
 *   editors      5 editors autosaving steps and fetching the health check, with
 *                some saves racing on one step (two tabs)
 *
 * Every acknowledged answer is logged as "ACK <scenario id> <step uuid>" so
 * test/load/checks/integrity.rb can prove each one was recorded. Halted answers
 * (the run could not act on them) log "HALT", and anything unexpected logs
 * "UNEXPECTED" with its status.
 *
 * Environment: BASE_URL, PASSWORD, CSRS (150), RAMP (5m), STEADY (30m),
 * RUSH_AT (2m), ONLY (comma-separated scenario names to run),
 * ANALYTICS_RANGES (7d,30d — the ranges managers open).
 *
 * Managers stay on 7 and 30 days by default. With a quarter's history loaded, a
 * 90-day Analytics view takes ~20s and pushes the 1.9 GiB VM into swap
 * (load-test report, finding 12), which would swamp every CSR measurement in the
 * launch gate. Measure 90 days on its own: ONLY=managers ANALYTICS_RANGES=90d.
 */

import http from 'k6/http';
import { sleep } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate, Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'https://localhost:8443';
const PASSWORD = __ENV.PASSWORD || 'LoadTest!2026';
const CSRS = parseInt(__ENV.CSRS || '150', 10);
const RAMP = __ENV.RAMP || '5m';
const STEADY = __ENV.STEADY || '30m';
const RUSH_AT = __ENV.RUSH_AT || '2m';
const ONLY = (__ENV.ONLY || '').split(',').filter(Boolean);
const ANALYTICS_RANGES = (__ENV.ANALYTICS_RANGES || '7d,30d').split(',').filter(Boolean);
const SANDBOX_WORKFLOW_ID = __ENV.SANDBOX_WORKFLOW_ID;
const SANDBOX_STEP_IDS = (__ENV.SANDBOX_STEP_IDS || '').split(',').filter(Boolean);

const answerDuration = new Trend('answer_duration', true);
const runPageDuration = new Trend('run_page_duration', true);
const signInDuration = new Trend('sign_in_duration', true);
const unexpected = new Rate('unexpected_responses');
const throttled = new Counter('throttled_429');
const haltedAnswers = new Counter('halted_answers');
const blockedAnswers = new Counter('blocked_answers');
const runsCompleted = new Counter('runs_completed');
const runsAbandoned = new Counter('runs_abandoned');
const backs = new Counter('backs');
const editorRaceErrors = new Counter('editor_race_errors');

const allScenarios = {
  csr_runs: {
    executor: 'ramping-vus',
    exec: 'csrShift',
    startVUs: 0,
    stages: [
      { duration: RAMP, target: CSRS },
      { duration: STEADY, target: CSRS },
      { duration: '1m', target: 0 },
    ],
    gracefulRampDown: '30s',
  },
  signin_rush: {
    executor: 'per-vu-iterations',
    exec: 'signinRush',
    vus: 50,
    iterations: 1,
    startTime: RUSH_AT,
    maxDuration: '10m',
  },
  managers: {
    executor: 'constant-vus',
    exec: 'managerDay',
    vus: 12,
    duration: STEADY,
    startTime: RAMP,
  },
  editors: {
    executor: 'constant-vus',
    exec: 'editorDay',
    vus: 5,
    duration: STEADY,
    startTime: RAMP,
  },
};

const scenarios = {};
for (const [name, config] of Object.entries(allScenarios)) {
  if (ONLY.length === 0 || ONLY.includes(name)) scenarios[name] = config;
}

export const options = {
  scenarios,
  insecureSkipTLSVerify: true,
  // k6 empties each VU's cookie jar after every iteration unless told not to.
  // A VU here signs in once and works many calls, so without this every
  // iteration after the first ran signed out — and a signed-out page request is
  // a redirect to a 200 sign-in page, which looked like success.
  noCookiesReset: true,
  thresholds: {
    answer_duration: ['p(95)<1000'],
    run_page_duration: ['p(95)<1500'],
    sign_in_duration: ['p(95)<2000'],
    unexpected_responses: ['rate<0.001'],
  },
};

// ---------------------------------------------------------------------------
// Per-VU state. Module scope is per VU in k6, and the cookie jar persists
// across a VU's iterations, so a VU signs in once.
// ---------------------------------------------------------------------------
let signedInAs = null;
let csrf = null;

const pad = (n, width) => String(n).padStart(width, '0');
const between = (min, max) => min + Math.random() * (max - min);
const pick = (list) => list[Math.floor(Math.random() * list.length)];

function metaCsrf(body) {
  const match = body && body.match(/name="csrf-token" content="([^"]+)"/);
  return match ? match[1] : null;
}

// Counts a response. 429s are the rate limiter doing its job and are counted
// apart; anything else outside `ok` is unexpected and logged.
function record(res, name, ok) {
  if (res.status === 429) {
    throttled.add(1, { name });
    unexpected.add(false);
    return false;
  }
  // Redirects are followed, so a lost session arrives as a 200 sign-in page.
  if (!name.startsWith('sign_in') && res.url && res.url.includes('/users/sign_in')) {
    unexpected.add(true);
    console.log(`SIGNED_OUT ${name} ${signedInAs}`);
    return false;
  }
  const fine = ok.includes(res.status);
  unexpected.add(!fine);
  if (!fine) console.log(`UNEXPECTED ${name} ${res.status} ${res.url}`);
  return fine;
}

function signIn(email) {
  if (signedInAs === email) return true;
  const page = http.get(`${BASE}/users/sign_in`, { tags: { name: 'sign_in_page' } });
  if (!record(page, 'sign_in_page', [200])) return false;
  const token = (page.body.match(/name="authenticity_token" value="([^"]+)"/) || [])[1];

  const res = http.post(`${BASE}/users/sign_in`,
    { 'user[email]': email, 'user[password]': PASSWORD, authenticity_token: token },
    { redirects: 0, tags: { name: 'sign_in' } });
  signInDuration.add(res.timings.duration);
  if (!record(res, 'sign_in', [302])) return false;

  signedInAs = email;
  return true;
}

// The CSRF token rotates on sign-in, so read it from a page fetched after.
function refreshCsrf(body) {
  csrf = metaCsrf(body) || csrf;
}

function post(url, data, name, ok, extraHeaders = {}) {
  const res = http.post(url, data, {
    redirects: 0,
    headers: Object.assign({ 'X-CSRF-Token': csrf }, extraHeaders),
    tags: { name },
  });
  record(res, name, ok);
  return res;
}

// ---------------------------------------------------------------------------
// CSRs
// ---------------------------------------------------------------------------

// The open card's step uuid: the id inside runner-card-current.
function openStepUuid(body) {
  const at = body.indexOf('id="runner-card-current"');
  if (at < 0) return null;
  const match = body.slice(at).match(/id="runner-card-([0-9a-f-]{36})"/);
  return match ? match[1] : null;
}

function nextScenarioId(body) {
  const matches = [...body.matchAll(/action="\/player\/scenarios\/(\d+)\/next"/g)];
  return matches.length ? matches[matches.length - 1][1] : null;
}

function idleOnHome(seconds) {
  const home = http.get(`${BASE}/`, { tags: { name: 'home' } });
  record(home, 'home', [200]);
  refreshCsrf(home.body);
  let left = seconds;
  while (left > 0) {
    const nap = Math.min(60, left);
    sleep(nap);
    left -= nap;
    if (left > 0) record(http.get(`${BASE}/session/heartbeat`, { tags: { name: 'heartbeat' } }), 'heartbeat', [200, 204]);
  }
}

export function csrShift() {
  if (!signIn(`csr${pad(exec.vu.idInTest, 3)}@loadtest.local`)) {
    sleep(30);
    return;
  }

  // Wrap-up from the last call, or arriving at the desk.
  idleOnHome(between(60, 180));

  const play = http.get(`${BASE}/play`, { tags: { name: 'play' } });
  if (!record(play, 'play', [200])) return;
  refreshCsrf(play.body);
  const workflowIds = [...play.body.matchAll(/action="\/play\/(\d+)"/g)].map((m) => m[1]);
  if (workflowIds.length === 0) {
    console.log(`UNEXPECTED play_empty ${signedInAs}`);
    unexpected.add(true);
    return;
  }

  const start = post(`${BASE}/play/${pick(workflowIds)}`, {}, 'start_run', [302]);
  if (start.status !== 302) return;

  let page = http.get(start.headers.Location, { tags: { name: 'run_page' } });
  runPageDuration.add(page.timings.duration);
  if (!record(page, 'run_page', [200])) return;

  let body = page.body;
  let scenarioId = nextScenarioId(body);
  const abandonAfter = Math.random() < 0.10 ? Math.floor(between(1, 5)) : Infinity;
  const backAfter = Math.random() < 0.05 ? Math.floor(between(2, 6)) : Infinity;

  for (let answered = 1; scenarioId && answered <= 40; answered++) {
    sleep(between(10, 20));

    const stepUuid = openStepUuid(body);
    const currentCard = body.slice(Math.max(0, body.indexOf('id="runner-card-current"')));
    const answer = currentCard.includes('value="yes"') ? (Math.random() < 0.7 ? 'yes' : 'no') : '';

    const res = post(`${BASE}/player/scenarios/${scenarioId}/next`, { answer }, 'answer', [200, 422],
      { Accept: 'text/vnd.turbo-stream.html' });
    answerDuration.add(res.timings.duration);

    if (res.status === 422) {
      blockedAnswers.add(1);
    } else if (res.status === 200 && res.body.includes('flash--alert')) {
      haltedAnswers.add(1);
      console.log(`HALT ${scenarioId} ${stepUuid}`);
    } else if (res.status === 200) {
      console.log(`ACK ${scenarioId} ${stepUuid}`);
    } else {
      return;
    }

    body = res.body;
    const following = nextScenarioId(body);
    if (!following) {
      runsCompleted.add(1);
      const results = body.match(/\/player\/scenarios\/(\d+)\/show/);
      if (results) {
        const show = http.get(`${BASE}/player/scenarios/${results[1]}/show`, { tags: { name: 'run_page' } });
        runPageDuration.add(show.timings.duration);
        record(show, 'results_page', [200]);
      }
      return;
    }
    scenarioId = following;

    if (answered === abandonAfter) {
      runsAbandoned.add(1); // closes the tab: nothing is sent
      return;
    }

    if (answered === backAfter) {
      sleep(between(3, 8));
      const back = post(`${BASE}/player/scenarios/${scenarioId}/back`, {}, 'back', [200],
        { Accept: 'text/vnd.turbo-stream.html' });
      backs.add(1);
      if (back.status === 200) {
        body = back.body;
        scenarioId = nextScenarioId(body) || scenarioId;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// First sign-in rush through /welcome
// ---------------------------------------------------------------------------
export function signinRush() {
  sleep(between(0, 300));
  const email = `rush${pad(exec.scenario.iterationInTest + 1, 3)}@loadtest.local`;
  if (!signIn(email)) return;

  const welcome = http.get(`${BASE}/`, { tags: { name: 'home_first_visit' } }); // follows to /welcome
  if (!record(welcome, 'welcome', [200])) return;
  if (!welcome.url.endsWith('/welcome')) {
    console.log(`UNEXPECTED not_sent_to_welcome ${email} ${welcome.url}`);
    unexpected.add(true);
    return;
  }
  refreshCsrf(welcome.body);

  const groupIds = [...welcome.body.matchAll(/<input[^>]*name="group_ids\[\]"[^>]*>/g)]
    .map((m) => (m[0].match(/value="(\d+)"/) || [])[1])
    .filter(Boolean);
  if (groupIds.length === 0) {
    console.log(`UNEXPECTED no_joinable_groups ${email}`);
    unexpected.add(true);
    return;
  }

  sleep(between(5, 20));
  const join = post(`${BASE}/welcome`, { 'group_ids[]': pick(groupIds) }, 'welcome_join', [302, 303]);
  if (join.status >= 300 && join.status < 400) {
    record(http.get(`${BASE}/`, { tags: { name: 'home' } }), 'home_after_join', [200]);
  }
}

// ---------------------------------------------------------------------------
// Managers
// ---------------------------------------------------------------------------
export function managerDay() {
  if (!signIn(`mgr${pad(((exec.vu.idInTest - 1) % 12) + 1, 2)}@loadtest.local`)) {
    sleep(30);
    return;
  }

  const analytics = http.get(`${BASE}/analytics?range=${pick(ANALYTICS_RANGES)}`, { tags: { name: 'analytics' } });
  record(analytics, 'analytics', [200]);
  sleep(between(20, 60));

  const teams = http.get(`${BASE}/teams`, { tags: { name: 'teams' } });
  if (record(teams, 'teams', [200])) {
    const teamIds = [...teams.body.matchAll(/href="\/teams\/(\d+)"/g)].map((m) => m[1]);
    if (teamIds.length) record(http.get(`${BASE}/teams/${pick(teamIds)}`, { tags: { name: 'team_page' } }), 'team_page', [200]);
  }
  sleep(between(30, 90));
  idleOnHome(between(30, 90));
}

// ---------------------------------------------------------------------------
// Editors
// ---------------------------------------------------------------------------
export function editorDay() {
  if (!SANDBOX_WORKFLOW_ID || SANDBOX_STEP_IDS.length === 0) {
    console.log('UNEXPECTED editors_need SANDBOX_WORKFLOW_ID and SANDBOX_STEP_IDS');
    sleep(60);
    return;
  }
  if (!signIn(`editor${pad(((exec.vu.idInTest - 1) % 5) + 1, 2)}@loadtest.local`)) {
    sleep(30);
    return;
  }

  const builder = http.get(`${BASE}/workflows/${SANDBOX_WORKFLOW_ID}`, { tags: { name: 'builder' } });
  if (!record(builder, 'builder', [200])) return;
  refreshCsrf(builder.body);
  sleep(between(5, 15));

  const stepId = pick(SANDBOX_STEP_IDS);
  const stepUrl = `${BASE}/workflows/${SANDBOX_WORKFLOW_ID}/steps/${stepId}`;
  record(http.get(`${stepUrl}/panel_edit`, { tags: { name: 'step_panel' } }), 'step_panel', [200]);
  sleep(between(3, 8));

  const stream = { Accept: 'text/vnd.turbo-stream.html', 'X-CSRF-Token': csrf };
  const title = { _method: 'patch', 'step[title]': `Sandbox step ${stepId} · ${Date.now()}` };

  if (Math.random() < 0.1) {
    // Two tabs saving the same step at the same instant.
    const [a, b] = http.batch([
      ['POST', stepUrl, title, { headers: stream, redirects: 0, tags: { name: 'autosave_race' } }],
      ['POST', stepUrl, title, { headers: stream, redirects: 0, tags: { name: 'autosave_race' } }],
    ]);
    for (const res of [a, b]) {
      if (res.status >= 500) {
        editorRaceErrors.add(1);
        console.log(`UNEXPECTED autosave_race ${res.status} step ${stepId}`);
      }
      record(res, 'autosave_race', [200]);
    }
  } else {
    record(http.post(stepUrl, title, { headers: stream, redirects: 0, tags: { name: 'autosave' } }), 'autosave', [200]);
  }

  sleep(0.5);
  record(http.get(`${BASE}/workflows/${SANDBOX_WORKFLOW_ID}/health.json`, { tags: { name: 'health' } }), 'health', [200]);
  sleep(between(10, 30));
}
