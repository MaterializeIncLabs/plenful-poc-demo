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
      c.claim_id,
      c.patient_id,
      c.status AS claim_status,
      c.submitted_at,
      c.payer_id,
      SUM(cli.billed_amount)   AS total_billed,
      SUM(cli.allowed_amount)  AS total_allowed,
      SUM(cli.paid_amount)     AS total_paid,
      pa.auth_number,
      pa.approved_units,
      pa.status AS auth_status
    FROM claims c
    JOIN claim_line_items cli ON cli.claim_id = c.claim_id
    LEFT JOIN prior_authorizations pa
           ON pa.patient_id = c.patient_id
          AND pa.payer_id   = c.payer_id
          AND pa.status = 'approved'
    WHERE c.submitted_at >= NOW() - INTERVAL '90 days'
    GROUP BY
      c.claim_id,
      c.patient_id,
      c.status,
      c.submitted_at,
      c.payer_id,
      pa.auth_number,
      pa.approved_units,
      pa.status
    LIMIT 100
  `.trim(),

  patient_360: `
    SELECT
      p.patient_id,
      p.first_name,
      p.last_name,
      p.date_of_birth,
      p.insurance_id,
      COUNT(DISTINCT c.claim_id)   AS total_claims,
      SUM(c.total_amount)          AS lifetime_spend,
      MAX(c.submitted_at)          AS last_claim_date,
      COUNT(DISTINCT pa.auth_id)   AS total_auths,
      COUNT(DISTINCT dr.dispense_id) AS total_dispenses
    FROM patients p
    LEFT JOIN claims c ON c.patient_id = p.patient_id
    LEFT JOIN prior_authorizations pa ON pa.patient_id = p.patient_id
    LEFT JOIN dispensing_records dr ON dr.patient_id = p.patient_id
    GROUP BY
      p.patient_id,
      p.first_name,
      p.last_name,
      p.date_of_birth,
      p.insurance_id
    LIMIT 100
  `.trim(),

  dispense_exceptions: `
    SELECT
      dr.dispense_id,
      dr.patient_id,
      dr.drug_code,
      dr.dispensed_qty,
      dr.dispensed_at,
      pa.approved_units,
      pa.auth_number,
      pa.expiration_date,
      (dr.dispensed_qty - pa.approved_units) AS qty_variance,
      CASE
        WHEN dr.dispensed_qty > pa.approved_units THEN 'over_dispensed'
        WHEN pa.auth_id IS NULL                   THEN 'no_auth'
        WHEN pa.expiration_date < dr.dispensed_at THEN 'auth_expired'
        ELSE 'ok'
      END AS exception_type
    FROM dispensing_records dr
    LEFT JOIN prior_authorizations pa
           ON pa.patient_id = dr.patient_id
          AND pa.drug_code  = dr.drug_code
          AND pa.status     = 'approved'
    WHERE dr.dispensed_at >= NOW() - INTERVAL '30 days'
    LIMIT 100
  `.trim(),

  workflow_summary: `
    SELECT
      w.workflow_id,
      w.workflow_type,
      w.assignee_id,
      w.created_at,
      w.priority,
      COUNT(we.event_id)                              AS total_events,
      MIN(we.occurred_at)                             AS first_event,
      MAX(we.occurred_at)                             AS last_event,
      SUM(CASE WHEN we.event_type = 'error' THEN 1 ELSE 0 END) AS error_count,
      EXTRACT(EPOCH FROM (MAX(we.occurred_at) - MIN(we.occurred_at))) AS duration_sec
    FROM workflows w
    LEFT JOIN workflow_events we ON we.workflow_id = w.workflow_id
    WHERE w.created_at >= NOW() - INTERVAL '7 days'
    GROUP BY
      w.workflow_id,
      w.workflow_type,
      w.assignee_id,
      w.created_at,
      w.priority
    LIMIT 100
  `.trim(),

  claims_pending: `
    SELECT
      c.claim_id,
      c.patient_id,
      c.payer_id,
      c.status,
      c.submitted_at,
      c.total_amount,
      COUNT(cli.line_id)           AS line_count,
      SUM(cli.billed_amount)       AS total_billed,
      SUM(cli.denied_amount)       AS total_denied,
      MIN(cli.service_date)        AS earliest_service,
      MAX(cli.service_date)        AS latest_service
    FROM claims c
    JOIN claim_line_items cli ON cli.claim_id = c.claim_id
    WHERE c.status IN ('pending', 'submitted', 'in_review')
    GROUP BY
      c.claim_id,
      c.patient_id,
      c.payer_id,
      c.status,
      c.submitted_at,
      c.total_amount
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
    SELECT
      c.claim_id,
      c.patient_id,
      c.payer_id,
      c.status,
      c.submitted_at,
      SUM(cli.billed_amount)  AS total_billed,
      SUM(cli.paid_amount)    AS total_paid,
      COUNT(cli.line_id)      AS line_count,
      pa.auth_number,
      pa.approved_units,
      pa.status               AS auth_status,
      dr.dispensed_qty,
      dr.drug_code
    FROM claims c
    JOIN claim_line_items cli
      ON cli.claim_id = c.claim_id
    LEFT JOIN prior_authorizations pa
      ON pa.patient_id = c.patient_id
     AND pa.payer_id   = c.payer_id
     AND pa.status     = 'approved'
    LEFT JOIN dispensing_records dr
      ON dr.patient_id = c.patient_id
     AND dr.drug_code  = pa.drug_code
    WHERE c.submitted_at >= NOW() - INTERVAL '180 days'
    GROUP BY
      c.claim_id,
      c.patient_id,
      c.payer_id,
      c.status,
      c.submitted_at,
      pa.auth_number,
      pa.approved_units,
      pa.status,
      dr.dispensed_qty,
      dr.drug_code;

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
  const bgwriterSql = `
    SELECT
      blks_hit,
      blks_read,
      CASE WHEN (blks_hit + blks_read) > 0
           THEN ROUND(100.0 * blks_hit / (blks_hit + blks_read), 2)
           ELSE 0
      END AS buffer_hit_rate
    FROM pg_stat_bgwriter
  `;

  const dbStatSql = `
    SELECT
      temp_files,
      temp_bytes
    FROM pg_stat_database
    WHERE datname = current_database()
  `;

  const activitySql = `
    SELECT COUNT(*) AS active_connections
    FROM pg_stat_activity
    WHERE state = 'active'
  `;

  try {
    const [bgResult, dbResult, actResult] = await Promise.all([
      pgPool.query(bgwriterSql),
      pgPool.query(dbStatSql),
      pgPool.query(activitySql),
    ]);

    const bg = bgResult.rows[0] || {};
    const db = dbResult.rows[0] || {};
    const act = actResult.rows[0] || {};

    return res.json({
      buffer_hit_rate: parseFloat(bg.buffer_hit_rate) || 0,
      active_connections: parseInt(act.active_connections, 10) || 0,
      temp_files: parseInt(db.temp_files, 10) || 0,
      temp_bytes: parseInt(db.temp_bytes, 10) || 0,
      cache_hit_pct: parseFloat(bg.buffer_hit_rate) || 0,
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
