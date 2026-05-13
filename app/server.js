require('dotenv').config();

const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 80;

// ─── Database Pools ──────────────────────────────────────────────────────────

const pgPool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || '5432', 10),
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  ssl: { rejectUnauthorized: false },
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

const mzPool = new Pool({
  host: process.env.MZ_HOST,
  port: parseInt(process.env.MZ_PORT || '6875', 10),
  user: process.env.MZ_USER,
  password: process.env.MZ_PASSWORD,
  database: process.env.MZ_DATABASE,
  ssl: { rejectUnauthorized: false },
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// ─── Materialize MV Queries ───────────────────────────────────────────────────

const MZ_QUERIES = {
  insurance_recon: 'SELECT * FROM mv_insurance_recon LIMIT 100',
  patient_360: 'SELECT * FROM mv_patient_360 LIMIT 100',
  dispense_exceptions: 'SELECT * FROM mv_dispense_exceptions LIMIT 100',
  workflow_summary: 'SELECT * FROM mv_workflow_summary LIMIT 100',
  claims_pending: 'SELECT * FROM mv_claims_pending LIMIT 100',
};

// ─── Aurora Raw Queries (no MV references) ────────────────────────────────────

const RAW_QUERIES = {
  insurance_recon: `
    SELECT
      c.org_id,
      c.id AS claim_id,
      c.patient_id,
      c.payer,
      c.billed_amount,
      c.paid_amount,
      c.billed_amount - COALESCE(c.paid_amount, 0) AS balance,
      c.status,
      COUNT(cli.id) AS line_item_count,
      SUM(cli.billed) AS total_billed,
      SUM(cli.paid) AS total_paid,
      pa.status AS auth_status,
      pa.auth_code
    FROM claims c
    JOIN claim_line_items cli ON cli.claim_id = c.id
    LEFT JOIN prior_authorizations pa ON pa.patient_id = c.patient_id
      AND pa.status = 'approved'
    WHERE c.status IN ('pending', 'partial')
    GROUP BY c.org_id, c.id, c.patient_id, c.payer,
             c.billed_amount, c.paid_amount, c.status,
             pa.status, pa.auth_code
    LIMIT 100
  `.trim(),

  patient_360: `
    SELECT
      p.id AS patient_id,
      p.org_id,
      p.mrn,
      COUNT(DISTINCT c.id) AS total_claims,
      SUM(c.billed_amount) AS total_billed,
      COUNT(DISTINCT pa.id) AS total_auths,
      COUNT(DISTINCT dr.id) AS total_dispenses,
      MAX(c.updated_at) AS last_claim_activity,
      MAX(pa.updated_at) AS last_auth_activity
    FROM patients p
    LEFT JOIN claims c ON c.patient_id = p.id
    LEFT JOIN prior_authorizations pa ON pa.patient_id = p.id
    LEFT JOIN dispensing_records dr ON dr.patient_id = p.id
    GROUP BY p.id, p.org_id, p.mrn, p.attributes
    LIMIT 100
  `.trim(),

  dispense_exceptions: `
    SELECT
      dr.id AS dispense_id,
      dr.patient_id,
      dr.org_id,
      dr.medication_code,
      dr.dispensed_at,
      dr.status,
      pa.status AS auth_status,
      pa.auth_code
    FROM dispensing_records dr
    LEFT JOIN prior_authorizations pa
      ON pa.patient_id = dr.patient_id
      AND pa.medication_code = dr.medication_code
    WHERE dr.status = 'held'
       OR pa.status IS NULL
       OR pa.status = 'denied'
    LIMIT 100
  `.trim(),

  workflow_summary: `
    SELECT
      w.org_id,
      w.id AS workflow_id,
      w.name,
      w.status,
      COUNT(we.id) AS total_events,
      COUNT(we.id) FILTER (WHERE we.created_at > NOW() - INTERVAL '1 hour') AS events_last_hour,
      MAX(we.created_at) AS last_event_at
    FROM workflows w
    LEFT JOIN workflow_events we ON we.workflow_id = w.id
    GROUP BY w.org_id, w.id, w.name, w.status
    LIMIT 100
  `.trim(),

  claims_pending: `
    SELECT
      c.id,
      c.org_id,
      c.patient_id,
      c.payer,
      c.status,
      c.billed_amount,
      c.paid_amount,
      c.service_date,
      COUNT(cli.id) AS line_items
    FROM claims c
    JOIN claim_line_items cli ON cli.claim_id = c.id
    WHERE c.status IN ('submitted', 'pending', 'partial')
    GROUP BY c.id, c.org_id, c.patient_id, c.payer,
             c.status, c.billed_amount, c.paid_amount, c.service_date
    LIMIT 100
  `.trim(),
};

// ─── Middleware ───────────────────────────────────────────────────────────────

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname)));

// ─── Helpers ──────────────────────────────────────────────────────────────────

function now() {
  return process.hrtime.bigint();
}

function elapsedMs(start) {
  return Number(process.hrtime.bigint() - start) / 1_000_000;
}

// ─── Routes ───────────────────────────────────────────────────────────────────

// GET /query/postgres?view=<name>
app.get('/query/postgres', async (req, res) => {
  const view = req.query.view || 'insurance_recon';
  const sql = RAW_QUERIES[view];

  if (!sql) {
    return res.status(400).json({ error: `Unknown view: ${view}` });
  }

  const start = now();
  try {
    const result = await pgPool.query(sql);
    const latency_ms = Math.round(elapsedMs(start));
    return res.json({
      latency_ms,
      row_count: result.rowCount,
      query: sql,
      source: 'aurora',
    });
  } catch (err) {
    const latency_ms = Math.round(elapsedMs(start));
    console.error('[postgres] query error:', err.message);
    return res.status(500).json({ error: err.message, latency_ms });
  }
});

// GET /query/materialize?view=<name>
app.get('/query/materialize', async (req, res) => {
  const view = req.query.view || 'insurance_recon';
  const sql = MZ_QUERIES[view];

  if (!sql) {
    return res.status(400).json({ error: `Unknown view: ${view}` });
  }

  const start = now();
  try {
    const result = await mzPool.query(sql);
    const latency_ms = Math.round(elapsedMs(start));
    return res.json({
      latency_ms,
      row_count: result.rowCount,
      query: sql,
      source: 'materialize',
    });
  } catch (err) {
    const latency_ms = Math.round(elapsedMs(start));
    console.error('[materialize] query error:', err.message);
    return res.status(500).json({ error: err.message, latency_ms });
  }
});

// POST /spike — TCS-style ad-hoc reconciliation spike on Aurora
app.post('/spike', async (req, res) => {
  const sql = `
    CREATE TEMP TABLE _spike_reconciliation AS
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
             pa.status, pa.auth_code;

    SELECT COUNT(*) FROM _spike_reconciliation;
    DROP TABLE IF EXISTS _spike_reconciliation;
  `;

  const start = now();
  let client;
  try {
    client = await pgPool.connect();
    await client.query(sql);
    const latency_ms = Math.round(elapsedMs(start));
    return res.json({
      latency_ms,
      message: `TCS reconciliation spike completed in ${latency_ms} ms`,
    });
  } catch (err) {
    const latency_ms = Math.round(elapsedMs(start));
    console.error('[spike] error:', err.message);
    return res.status(500).json({ error: err.message, latency_ms });
  } finally {
    if (client) client.release();
  }
});

// GET /metrics — Aurora pg_stat diagnostics
app.get('/metrics', async (req, res) => {
  const dbStatSql = `
    SELECT
      blks_hit,
      blks_read,
      temp_files,
      temp_bytes,
      CASE WHEN (blks_hit + blks_read) > 0
           THEN ROUND(100.0 * blks_hit / (blks_hit + blks_read), 2)
           ELSE 0
      END AS buffer_hit_rate
    FROM pg_stat_database
    WHERE datname = current_database()
  `;

  const activitySql = `
    SELECT COUNT(*) AS active_connections
    FROM pg_stat_activity
    WHERE state = 'active'
  `;

  try {
    const [dbResult, actResult] = await Promise.all([
      pgPool.query(dbStatSql),
      pgPool.query(activitySql),
    ]);

    const db = dbResult.rows[0] || {};
    const act = actResult.rows[0] || {};

    return res.json({
      buffer_hit_rate: parseFloat(db.buffer_hit_rate) || 0,
      active_connections: parseInt(act.active_connections, 10) || 0,
      temp_files: parseInt(db.temp_files, 10) || 0,
      temp_bytes: parseInt(db.temp_bytes, 10) || 0,
      cache_hit_pct: parseFloat(db.buffer_hit_rate) || 0,
    });
  } catch (err) {
    console.error('[metrics] error:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// GET /loadgen/status
app.get('/loadgen/status', (req, res) => {
  const statusFile = '/tmp/loadgen-status.json';
  try {
    if (fs.existsSync(statusFile)) {
      const data = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
      return res.json(data);
    }
  } catch (_) {
    // fall through to default
  }
  return res.json({ workers: 0, mode: 'idle', qps: 0 });
});

// POST /loadgen/config
app.post('/loadgen/config', (req, res) => {
  const { workers, mode } = req.body || {};
  const config = { workers: workers ?? 0, mode: mode ?? 'idle' };
  try {
    fs.writeFileSync('/tmp/loadgen-config.json', JSON.stringify(config, null, 2));
    return res.json({ ok: true, config });
  } catch (err) {
    console.error('[loadgen/config] write error:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ─── Start ────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Plenful POC demo listening on port ${PORT}`);
});
