/**
 * TurboFlows k6 Concurrent Editing Load Test
 *
 * Tests concurrent editing scenarios:
 *  - Multiple users PATCH the same workflow with optimistic locking
 *  - Concurrent scenario step advancement
 *  - Measures conflict rate, save latency, and step sync latency
 *
 * Run:
 *   k6 run test/load/k6-concurrent-editing.js
 *
 * Environment variables:
 *   BASE_URL  - Target URL (default: http://localhost:3000)
 *   EMAIL_PREFIX - Prefix for test user emails (default: loadtest)
 *   PASSWORD  - Shared test user password (default: password123!)
 *   VUS       - Virtual users (default: 5)
 *   DURATION  - Test duration (default: 2m)
 *   WORKFLOW_ID - Target workflow ID for editing tests
 */

import http from 'k6/http';
import { check, sleep, group, fail } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';

// ── Custom Metrics ──────────────────────────────────────────────────────────

const conflictRate = new Rate('conflict_rate');
const errorRate = new Rate('errors');
const saveTrend = new Trend('save_latency', true);
const stepSyncTrend = new Trend('step_sync_latency', true);
const scenarioAdvanceTrend = new Trend('scenario_advance_latency', true);
const conflictsTotal = new Counter('conflicts_total');

// ── Options ─────────────────────────────────────────────────────────────────

const VUS = parseInt(__ENV.VUS || '5');
const DURATION = __ENV.DURATION || '2m';

export const options = {
  scenarios: {
    concurrent_editors: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    save_latency:   ['p(95)<2000'],       // p95 save < 2s
    step_sync_latency: ['p(95)<2000'],    // p95 step sync < 2s
    conflict_rate:  ['rate<0.10'],         // conflicts < 10%
    errors:         ['rate<0.05'],         // errors < 5%
  },
};

// ── Config ──────────────────────────────────────────────────────────────────

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';
const EMAIL_PREFIX = __ENV.EMAIL_PREFIX || 'loadtest';
const PASSWORD = __ENV.PASSWORD || 'password123!';
const WORKFLOW_ID = __ENV.WORKFLOW_ID || '';

// ── Per-VU State ────────────────────────────────────────────────────────────

let session = {
  csrfToken: null,
  authenticityToken: null,
  authenticated: false,
  workflowId: null,
  lockVersion: 0,
  scenarioId: null,
};

// ── Helpers ─────────────────────────────────────────────────────────────────

function extractCsrfToken(html) {
  const m = html.match(/name="csrf-token" content="([^"]+)"/);
  return m ? m[1] : null;
}

function extractAuthenticityToken(html) {
  const m = html.match(/name="authenticity_token" value="([^"]+)"/);
  return m ? m[1] : null;
}

function extractLockVersion(html) {
  const m = html.match(/name="workflow\[lock_version\]" value="(\d+)"/);
  return m ? parseInt(m[1]) : 0;
}

function authenticate() {
  const vuId = __VU;
  const email = `${EMAIL_PREFIX}+vu${vuId}@example.com`;

  const loginPage = http.get(`${BASE_URL}/users/sign_in`);
  if (loginPage.status !== 200) {
    console.error(`VU ${vuId}: failed to load login page (${loginPage.status})`);
    return false;
  }

  session.csrfToken = extractCsrfToken(loginPage.body);
  const authToken = extractAuthenticityToken(loginPage.body);

  const res = http.post(`${BASE_URL}/users/sign_in`, {
    'user[email]': email,
    'user[password]': PASSWORD,
    authenticity_token: authToken,
  }, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    redirects: 5,
  });

  session.authenticated = res.status === 200 || res.status === 302;
  if (!session.authenticated) {
    console.error(`VU ${vuId}: login failed (${res.status})`);
  }
  return session.authenticated;
}

function loadWorkflow() {
  const id = WORKFLOW_ID || session.workflowId;
  if (!id) {
    // Pick the first workflow from the list
    const listRes = http.get(`${BASE_URL}/workflows`, {
      headers: { 'X-CSRF-Token': session.csrfToken },
    });
    const m = listRes.body.match(/workflows\/(\d+)/);
    if (m) session.workflowId = m[1];
    return;
  }
  session.workflowId = id;

  const res = http.get(`${BASE_URL}/workflows/${id}/edit`, {
    headers: { 'X-CSRF-Token': session.csrfToken },
  });

  if (res.status === 200) {
    session.csrfToken = extractCsrfToken(res.body) || session.csrfToken;
    session.authenticityToken = extractAuthenticityToken(res.body);
    session.lockVersion = extractLockVersion(res.body);
  }
}

// ── Test Actions ────────────────────────────────────────────────────────────

function concurrentWorkflowPatch() {
  if (!session.workflowId) return;

  group('Concurrent PATCH workflow', () => {
    // Reload to get a fresh lock_version and authenticity token
    const editRes = http.get(`${BASE_URL}/workflows/${session.workflowId}/edit`, {
      headers: { 'X-CSRF-Token': session.csrfToken },
    });

    if (editRes.status !== 200) {
      errorRate.add(1);
      return;
    }

    session.csrfToken = extractCsrfToken(editRes.body) || session.csrfToken;
    session.authenticityToken = extractAuthenticityToken(editRes.body);
    session.lockVersion = extractLockVersion(editRes.body);

    const start = Date.now();
    const res = http.post(`${BASE_URL}/workflows/${session.workflowId}`, {
      _method: 'patch',
      authenticity_token: session.authenticityToken,
      'workflow[title]': `Concurrent Edit VU${__VU} ${Date.now()}`,
      'workflow[lock_version]': session.lockVersion.toString(),
    }, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-CSRF-Token': session.csrfToken,
      },
      redirects: 5,
    });
    saveTrend.add(Date.now() - start);

    const isConflict = res.status === 409 || (res.body && res.body.includes('stale'));
    const isSuccess = res.status === 200 || res.status === 302;

    conflictRate.add(isConflict ? 1 : 0);
    errorRate.add(!isSuccess && !isConflict ? 1 : 0);

    if (isConflict) conflictsTotal.add(1);

    check(res, {
      'patch succeeds or gets conflict': () => isSuccess || isConflict,
    });
  });
}

function concurrentStepSync() {
  if (!session.workflowId) return;

  group('Concurrent step sync', () => {
    const editRes = http.get(`${BASE_URL}/workflows/${session.workflowId}/edit`, {
      headers: { 'X-CSRF-Token': session.csrfToken },
    });

    if (editRes.status !== 200) {
      errorRate.add(1);
      return;
    }

    session.csrfToken = extractCsrfToken(editRes.body) || session.csrfToken;
    session.authenticityToken = extractAuthenticityToken(editRes.body);

    const start = Date.now();
    const res = http.post(
      `${BASE_URL}/workflows/${session.workflowId}/step_sync`,
      {
        _method: 'patch',
        authenticity_token: session.authenticityToken,
      },
      {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-CSRF-Token': session.csrfToken,
          Accept: 'text/vnd.turbo-stream.html',
        },
        redirects: 0,
      }
    );
    stepSyncTrend.add(Date.now() - start);

    const ok = res.status >= 200 && res.status < 400;
    errorRate.add(ok ? 0 : 1);
    check(res, {
      'step sync responds': () => ok,
    });
  });
}

function concurrentScenarioAdvance() {
  if (!session.workflowId) return;

  group('Concurrent scenario advance', () => {
    // Create a new scenario if needed
    if (!session.scenarioId) {
      const startRes = http.get(`${BASE_URL}/play/${session.workflowId}`, {
        headers: { 'X-CSRF-Token': session.csrfToken },
        redirects: 5,
      });

      if (startRes.status === 200) {
        const m = startRes.url.match(/scenarios\/(\d+)/);
        if (m) session.scenarioId = m[1];
      }
    }

    if (!session.scenarioId) return;

    const stepRes = http.get(
      `${BASE_URL}/player/scenarios/${session.scenarioId}/step`,
      { headers: { 'X-CSRF-Token': session.csrfToken } }
    );

    if (stepRes.status !== 200) {
      session.scenarioId = null; // Reset for next iteration
      return;
    }

    session.csrfToken = extractCsrfToken(stepRes.body) || session.csrfToken;
    const authToken = extractAuthenticityToken(stepRes.body);

    const start = Date.now();
    const advanceRes = http.post(
      `${BASE_URL}/player/scenarios/${session.scenarioId}/next_step`,
      {
        authenticity_token: authToken,
        answer: 'yes',
      },
      {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-CSRF-Token': session.csrfToken,
        },
        redirects: 5,
      }
    );
    scenarioAdvanceTrend.add(Date.now() - start);

    const ok = advanceRes.status >= 200 && advanceRes.status < 400;
    errorRate.add(ok ? 0 : 1);

    check(advanceRes, {
      'scenario advance responds': () => ok,
    });

    // If scenario completed, reset for next iteration
    if (advanceRes.url && advanceRes.url.includes('/show')) {
      session.scenarioId = null;
    }
  });
}

// ── Main Loop ───────────────────────────────────────────────────────────────

export function setup() {
  console.log(`Concurrent editing load test targeting: ${BASE_URL}`);
  console.log(`VUs: ${VUS}, Duration: ${DURATION}`);
  console.log('Ensure test users exist (loadtest+vu1..N@example.com) before running.');
  return { startTime: Date.now() };
}

export default function () {
  if (!session.authenticated) {
    if (!authenticate()) {
      errorRate.add(1);
      sleep(5);
      return;
    }
    loadWorkflow();
  }

  if (!session.workflowId) {
    loadWorkflow();
    if (!session.workflowId) {
      sleep(2);
      return;
    }
  }

  // Randomly choose an action, weighted toward editing
  const action = randomIntBetween(1, 10);

  if (action <= 5) {
    concurrentWorkflowPatch();
  } else if (action <= 8) {
    concurrentStepSync();
  } else {
    concurrentScenarioAdvance();
  }

  sleep(randomIntBetween(1, 3));
}

export function teardown(data) {
  const duration = (Date.now() - data.startTime) / 1000;
  console.log(`Concurrent editing test completed in ${duration.toFixed(1)}s`);
}
