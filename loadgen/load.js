'use strict';

/**
 * Plenful POC — Load Generator
 *
 * Hammers Aurora Postgres with raw SQL and Materialize with materialized view
 * queries. Exposes a tiny HTTP API on port 3001 for the app server to control
 * worker count and mode.
 *
 * Usage:
 *   node load.js
 *
 * HTTP API:
 *   GET  http://127.0.0.1:3001/status   — current runtime stats
 *   POST http://127.0.0.1:3001/config   — { "workers": 5, "mode": "steady" }
 *
 * Status is also written to /tmp/loadgen-status.json every 2 s.
 * Config is read from /tmp/loadgen-config.json every 2 s.
 */

require('dotenv').config({ path: require('path').resolve(__dirname, '../app/.env') });

const http = require('http');
const fs   = require('fs');
const { Pool } = require('pg');

// ---------------------------------------------------------------------------
// Connection pools
// ---------------------------------------------------------------------------

const pgPool = new Pool({
  host:     process.env.AURORA_HOST     || process.env.DB_HOST,
  port:     parseInt(process.env.AURORA_PORT || process.env.DB_PORT || '5432', 10),
  database: process.env.AURORA_DB       || process.env.DB_NAME,
  user:     process.env.AURORA_USER     || process.env.DB_USER,
  password: process.env.AURORA_PASSWORD || process.env.DB_PASS,
  max:      30,
  idleTimeoutMillis: 60000,
  connectionTimeoutMillis: 10000,
  ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
});

const mzPool = new Pool({
  host:     process.env.MZ_HOST,
  port:     parseInt(process.env.MZ_PORT || '6875', 10),
  database: process.env.MZ_DB   || 'materialize',
  user:     process.env.MZ_USER,
  password: process.env.MZ_PASSWORD,
  max:      20,
  idleTimeoutMillis: 60000,
  connectionTimeoutMillis: 10000,
  ssl: process.env.MZ_SSL === 'false' ? false : { rejectUnauthorized: false },
});

pgPool.on('error', (err) => console.error('[pg-pool] idle client error:', err.message));
mzPool.on('error', (err) => console.error('[mz-pool] idle client error:', err.message));

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

const STEADY_PG_QUERY = `
SELECT
  c.id,
  c.org_id,
  c.patient_id,
  c.payer,
  c.billed_amount,
  c.paid_amount,
  c.billed_amount - COALESCE(c.paid_amount, 0) AS balance,
  c.status,
  COUNT(cli.id)    AS line_item_count,
  SUM(cli.billed)  AS total_billed,
  SUM(cli.paid)    AS total_paid,
  pa.status        AS auth_status,
  pa.auth_code
FROM claims c
JOIN claim_line_items cli ON cli.claim_id = c.id
LEFT JOIN prior_authorizations pa
  ON pa.patient_id = c.patient_id AND pa.status = 'approved'
WHERE c.status IN ('pending', 'partial')
  AND c.service_date > NOW() - INTERVAL '180 days'
GROUP BY
  c.org_id, c.id, c.patient_id, c.payer,
  c.billed_amount, c.paid_amount, c.status,
  pa.status, pa.auth_code
LIMIT 1000;
`.trim();

const STEADY_MZ_QUERY = `
SELECT
  claim_id, org_id, patient_id, payer,
  billed_amount, paid_amount, balance,
  claim_status, line_item_count,
  total_billed, total_paid,
  auth_status, auth_code,
  service_date, updated_at
FROM mv_insurance_recon
LIMIT 1000;
`.trim();

// Spike mode: runs a temp-table chain against Aurora
const SPIKE_PG_QUERIES = [
  `CREATE TEMP TABLE IF NOT EXISTS _recon_tmp AS
SELECT c.id, c.org_id, c.patient_id, c.payer,
       c.billed_amount, c.paid_amount,
       c.billed_amount - COALESCE(c.paid_amount, 0) AS balance,
       c.status,
       COUNT(cli.id) AS line_item_count,
       SUM(cli.billed) AS total_billed,
       SUM(cli.paid) AS total_paid,
       pa.status AS auth_status,
       pa.auth_code
FROM claims c
JOIN claim_line_items cli ON cli.claim_id = c.id
LEFT JOIN prior_authorizations pa ON pa.patient_id = c.patient_id AND pa.status = 'approved'
WHERE c.status IN ('pending', 'partial')
  AND c.service_date > NOW() - INTERVAL '180 days'
GROUP BY c.org_id, c.id, c.patient_id, c.payer,
         c.billed_amount, c.paid_amount, c.status,
         pa.status, pa.auth_code;`,
  `SELECT COUNT(*) FROM _recon_tmp;`,
  `DROP TABLE IF EXISTS _recon_tmp;`,
];

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

let state = {
  workers:    5,
  mode:       'steady',  // 'steady' | 'spike'
  running:    true,
  pgQueries:  0,         // total lifetime PG queries
  mzQueries:  0,         // total lifetime MZ queries
  pgQps:      0,         // rolling 1-second rate
  mzQps:      0,
  errors:     0,
  startedAt:  Date.now(),
};

// Ring buffers for QPS calculation (count per 1 s bucket, keep last 5)
const QPS_WINDOW = 5;
let pgBucket  = Array(QPS_WINDOW).fill(0);
let mzBucket  = Array(QPS_WINDOW).fill(0);
let bucketIdx = 0;

// Active worker timer handles — keyed by worker id
const workerTimers = new Map();

// ---------------------------------------------------------------------------
// QPS tracking
// ---------------------------------------------------------------------------

setInterval(() => {
  bucketIdx = (bucketIdx + 1) % QPS_WINDOW;
  pgBucket[bucketIdx] = 0;
  mzBucket[bucketIdx] = 0;
}, 1000);

setInterval(() => {
  // Average over non-zero buckets
  state.pgQps = Math.round(pgBucket.reduce((a, b) => a + b, 0) / QPS_WINDOW);
  state.mzQps = Math.round(mzBucket.reduce((a, b) => a + b, 0) / QPS_WINDOW);
}, 1000);

// ---------------------------------------------------------------------------
// Worker functions
// ---------------------------------------------------------------------------

async function runSteadyPgQuery(workerId) {
  const start = Date.now();
  try {
    const res = await pgPool.query(STEADY_PG_QUERY);
    const ms  = Date.now() - start;
    state.pgQueries++;
    pgBucket[bucketIdx]++;
    console.log(`[pg-steady][worker-${workerId}] ${res.rowCount} rows in ${ms}ms`);
  } catch (err) {
    state.errors++;
    console.error(`[pg-steady][worker-${workerId}] ERROR: ${err.message}`);
  }
}

async function runSteadyMzQuery(workerId) {
  const start = Date.now();
  try {
    const res = await mzPool.query(STEADY_MZ_QUERY);
    const ms  = Date.now() - start;
    state.mzQueries++;
    mzBucket[bucketIdx]++;
    console.log(`[mz-steady][worker-${workerId}] ${res.rowCount} rows in ${ms}ms`);
  } catch (err) {
    state.errors++;
    console.error(`[mz-steady][worker-${workerId}] ERROR: ${err.message}`);
  }
}

async function runSpikePgQuery(workerId) {
  const client = await pgPool.connect();
  const start  = Date.now();
  try {
    for (const sql of SPIKE_PG_QUERIES) {
      await client.query(sql);
    }
    const ms = Date.now() - start;
    state.pgQueries++;
    pgBucket[bucketIdx]++;
    console.log(`[pg-spike][worker-${workerId}] temp-table chain done in ${ms}ms`);
  } catch (err) {
    state.errors++;
    console.error(`[pg-spike][worker-${workerId}] ERROR: ${err.message}`);
    // Ensure temp table is dropped even on error
    try { await client.query('DROP TABLE IF EXISTS _recon_tmp;'); } catch (_) {}
  } finally {
    client.release();
  }
}

async function runSpikeMzQuery(workerId) {
  const start = Date.now();
  try {
    const res = await mzPool.query(STEADY_MZ_QUERY);
    const ms  = Date.now() - start;
    state.mzQueries++;
    mzBucket[bucketIdx]++;
    console.log(`[mz-spike][worker-${workerId}] ${res.rowCount} rows in ${ms}ms`);
  } catch (err) {
    state.errors++;
    console.error(`[mz-spike][worker-${workerId}] ERROR: ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// Worker lifecycle
// ---------------------------------------------------------------------------

function workerIntervalMs() {
  return state.mode === 'spike' ? 5000 : 30000;
}

function spawnWorker(workerId) {
  if (workerTimers.has(workerId)) return; // already running

  // Stagger startup so workers don't fire simultaneously
  const staggerMs = state.mode === 'steady'
    ? (workerId * Math.floor(30000 / state.workers))
    : (workerId * 333);

  console.log(`[loadgen] spawning worker-${workerId} (stagger ${staggerMs}ms, mode=${state.mode})`);

  const startTimer = setTimeout(() => {
    const tick = async () => {
      if (!state.running || !workerTimers.has(workerId)) return;

      if (state.mode === 'spike') {
        await Promise.allSettled([
          runSpikePgQuery(workerId),
          runSpikeMzQuery(workerId),
        ]);
      } else {
        await Promise.allSettled([
          runSteadyPgQuery(workerId),
          runSteadyMzQuery(workerId),
        ]);
      }

      // Re-schedule (interval may have changed)
      if (state.running && workerTimers.has(workerId)) {
        const handle = setTimeout(tick, workerIntervalMs());
        workerTimers.set(workerId, handle);
      }
    };

    tick();
  }, staggerMs);

  workerTimers.set(workerId, startTimer);
}

function stopWorker(workerId) {
  const handle = workerTimers.get(workerId);
  if (handle) {
    clearTimeout(handle);
    workerTimers.delete(workerId);
    console.log(`[loadgen] stopped worker-${workerId}`);
  }
}

function reconcileWorkers(targetCount, mode) {
  const prevMode = state.mode;
  state.mode    = mode;
  state.workers = targetCount;

  // If mode changed, stop all workers and restart
  if (mode !== prevMode) {
    console.log(`[loadgen] mode changed ${prevMode} -> ${mode}, restarting all workers`);
    for (const id of workerTimers.keys()) stopWorker(id);
  }

  const currentWorkers = workerTimers.size;

  if (currentWorkers < targetCount) {
    for (let i = currentWorkers; i < targetCount; i++) {
      spawnWorker(i);
    }
  } else if (currentWorkers > targetCount) {
    const toStop = currentWorkers - targetCount;
    const ids    = [...workerTimers.keys()].sort((a, b) => b - a); // remove highest ids first
    for (let i = 0; i < toStop; i++) {
      stopWorker(ids[i]);
    }
  }
}

// ---------------------------------------------------------------------------
// Status / config file I/O
// ---------------------------------------------------------------------------

const STATUS_PATH = '/tmp/loadgen-status.json';
const CONFIG_PATH = '/tmp/loadgen-config.json';

function writeStatus() {
  const payload = {
    workers:    state.workers,
    mode:       state.mode,
    pg_qps:     state.pgQps,
    mz_qps:     state.mzQps,
    pg_queries: state.pgQueries,
    mz_queries: state.mzQueries,
    errors:     state.errors,
    running:    state.running,
    uptime_s:   Math.floor((Date.now() - state.startedAt) / 1000),
    ts:         new Date().toISOString(),
  };
  try {
    fs.writeFileSync(STATUS_PATH, JSON.stringify(payload, null, 2));
  } catch (err) {
    console.error('[loadgen] failed to write status file:', err.message);
  }
}

function readConfig() {
  try {
    if (!fs.existsSync(CONFIG_PATH)) return;
    const raw    = fs.readFileSync(CONFIG_PATH, 'utf8');
    const config = JSON.parse(raw);
    const newWorkers = parseInt(config.workers, 10);
    const newMode    = config.mode;
    if (
      !isNaN(newWorkers) &&
      newWorkers > 0 &&
      newWorkers <= 50 &&
      (newMode === 'steady' || newMode === 'spike') &&
      (newWorkers !== state.workers || newMode !== state.mode)
    ) {
      console.log(`[loadgen] config change from file: workers=${newWorkers} mode=${newMode}`);
      reconcileWorkers(newWorkers, newMode);
    }
  } catch (err) {
    // Ignore parse errors — file may be mid-write
  }
}

setInterval(writeStatus, 2000);
setInterval(readConfig,  2000);

// ---------------------------------------------------------------------------
// HTTP control server (localhost only)
// ---------------------------------------------------------------------------

function sendJson(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type':   'application/json',
    'Content-Length': Buffer.byteLength(json),
  });
  res.end(json);
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // GET /status
  if (req.method === 'GET' && url === '/status') {
    return sendJson(res, 200, {
      workers:    state.workers,
      mode:       state.mode,
      pg_qps:     state.pgQps,
      mz_qps:     state.mzQps,
      pg_queries: state.pgQueries,
      mz_queries: state.mzQueries,
      errors:     state.errors,
      running:    state.running,
      uptime_s:   Math.floor((Date.now() - state.startedAt) / 1000),
    });
  }

  // POST /config
  if (req.method === 'POST' && url === '/config') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const config     = JSON.parse(body);
        const newWorkers = parseInt(config.workers, 10);
        const newMode    = config.mode;

        if (isNaN(newWorkers) || newWorkers < 1 || newWorkers > 50) {
          return sendJson(res, 400, { error: 'workers must be between 1 and 50' });
        }
        if (newMode !== 'steady' && newMode !== 'spike') {
          return sendJson(res, 400, { error: 'mode must be "steady" or "spike"' });
        }

        reconcileWorkers(newWorkers, newMode);
        console.log(`[loadgen] HTTP config update: workers=${newWorkers} mode=${newMode}`);
        return sendJson(res, 200, { ok: true, workers: state.workers, mode: state.mode });
      } catch (err) {
        return sendJson(res, 400, { error: 'invalid JSON body' });
      }
    });
    return;
  }

  sendJson(res, 404, { error: 'not found' });
});

server.listen(3001, '127.0.0.1', () => {
  console.log('[loadgen] HTTP control server listening on http://127.0.0.1:3001');
});

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

console.log('[loadgen] starting — mode=steady workers=5');
reconcileWorkers(state.workers, state.mode);

// Write initial status immediately
writeStatus();

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

function shutdown() {
  console.log('[loadgen] shutting down...');
  state.running = false;
  for (const id of workerTimers.keys()) stopWorker(id);
  server.close(() => {
    pgPool.end(() => {
      mzPool.end(() => {
        console.log('[loadgen] bye.');
        process.exit(0);
      });
    });
  });
}

process.on('SIGTERM', shutdown);
process.on('SIGINT',  shutdown);
