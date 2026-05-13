-- Efficient reseed for claims, claim_line_items, dispensing_records, workflows, workflow_events
-- Uses row-number temp tables instead of LATERAL OFFSET to avoid O(n²) scans

-- ============================================================
-- BUILD HELPER TEMP TABLES (indexed, O(n) scan each)
-- ============================================================

CREATE TEMP TABLE pt AS
SELECT id, org_id, row_number() OVER (ORDER BY id) - 1 AS rn
FROM patients;

CREATE INDEX ON pt(rn);

-- ============================================================
-- CLAIMS  (500,000)
-- ============================================================
BEGIN;

INSERT INTO claims (
  id, patient_id, org_id, payer,
  status, billed_amount, paid_amount,
  service_date, reconciled, created_at, updated_at
)
SELECT
  gen_random_uuid(),
  p.id,
  p.org_id,
  (ARRAY['BlueStar Insurance','Apex Health Coverage','National Care Plans','Horizon Benefits Group','Medicare','Medicaid'])
    [ 1 + (s.i % 6) ],
  CASE
    WHEN s.i % 100 < 60 THEN 'paid'
    WHEN s.i % 100 < 80 THEN 'pending'
    WHEN s.i % 100 < 90 THEN 'partial'
    WHEN s.i % 100 < 95 THEN 'denied'
    WHEN s.i % 100 < 98 THEN 'submitted'
    ELSE                      'reconciled'
  END,
  round((50 + random() * 4950)::NUMERIC, 2),
  CASE
    WHEN s.i % 100 < 60 THEN round((50 + random() * 4950)::NUMERIC * (0.7 + random() * 0.25), 2)
    WHEN s.i % 100 < 90 THEN round((50 + random() * 4950)::NUMERIC * (0.3 + random() * 0.4),  2)
    ELSE                      NULL
  END,
  (CURRENT_DATE - (random() * 365 * 2)::INT),
  CASE WHEN s.i % 100 >= 98 THEN TRUE ELSE FALSE END,
  NOW() - (random() * 540)::INT * INTERVAL '1 day',
  NOW() - (random() * 30)::INT  * INTERVAL '1 day'
FROM generate_series(0, 499999) AS s(i)
JOIN pt p ON p.rn = (s.i % 100000);

COMMIT;

-- ============================================================
-- CLAIM LINE ITEMS  (~1.25M)
-- ============================================================
BEGIN;

INSERT INTO claim_line_items (id, claim_id, procedure_code, billed, paid, status, created_at)
SELECT
  gen_random_uuid(),
  c.id,
  (ARRAY['99213','99214','99215','99203','99204','93000','71046','80053','36415','90658'])
    [ 1 + (row_number() OVER () % 10) ],
  round((c.billed_amount * (0.3 + random() * 0.4))::NUMERIC, 2),
  CASE WHEN c.paid_amount IS NOT NULL
       THEN round((c.paid_amount * (0.3 + random() * 0.4))::NUMERIC, 2)
       ELSE NULL END,
  c.status,
  c.created_at
FROM claims c;

COMMIT;

BEGIN;

INSERT INTO claim_line_items (id, claim_id, procedure_code, billed, paid, status, created_at)
SELECT
  gen_random_uuid(),
  c.id,
  (ARRAY['99213','99214','99215','99203','99204','93000','71046','80053','36415','90658'])
    [ 1 + ((row_number() OVER () + 3) % 10) ],
  round((c.billed_amount * (0.2 + random() * 0.3))::NUMERIC, 2),
  CASE WHEN c.paid_amount IS NOT NULL
       THEN round((c.paid_amount * (0.2 + random() * 0.3))::NUMERIC, 2)
       ELSE NULL END,
  c.status,
  c.created_at
FROM claims c
WHERE random() < 0.75;

COMMIT;

BEGIN;

INSERT INTO claim_line_items (id, claim_id, procedure_code, billed, paid, status, created_at)
SELECT
  gen_random_uuid(),
  c.id,
  (ARRAY['99213','99214','99215','99203','99204','93000','71046','80053','36415','90658'])
    [ 1 + ((row_number() OVER () + 7) % 10) ],
  round((c.billed_amount * (0.1 + random() * 0.2))::NUMERIC, 2),
  CASE WHEN c.paid_amount IS NOT NULL
       THEN round((c.paid_amount * (0.1 + random() * 0.2))::NUMERIC, 2)
       ELSE NULL END,
  c.status,
  c.created_at
FROM claims c
WHERE random() < 0.50;

COMMIT;

-- ============================================================
-- DISPENSING RECORDS  (150,000) — requires prior_authorizations
-- ============================================================

CREATE TEMP TABLE pa_ids AS
SELECT id, medication_code, row_number() OVER (ORDER BY id) - 1 AS rn
FROM prior_authorizations;

CREATE INDEX ON pa_ids(rn);

BEGIN;

INSERT INTO dispensing_records (
  id, patient_id, org_id, prior_auth_id,
  medication_code, dispensed_at, quantity, status,
  created_at
)
SELECT
  gen_random_uuid(),
  p.id,
  (ARRAY[
    '00000001-0000-0000-0000-000000000004',
    '00000001-0000-0000-0000-000000000005',
    '00000001-0000-0000-0000-000000000006'
  ])[ 1 + (s.i % 3) ]::UUID,
  pa.id,
  pa.medication_code,
  NOW() - (random() * 365)::INT * INTERVAL '1 day',
  round((1 + random() * 90)::NUMERIC, 0),
  CASE
    WHEN s.i % 100 < 85 THEN 'dispensed'
    WHEN s.i % 100 < 95 THEN 'held'
    ELSE                      'returned'
  END,
  NOW() - (random() * 365)::INT * INTERVAL '1 day'
FROM generate_series(0, 149999) AS s(i)
JOIN pt p   ON p.rn  = (s.i % 100000)
JOIN pa_ids pa ON pa.rn = (s.i % 200000);

COMMIT;

-- ============================================================
-- WORKFLOWS  (50 total)
-- ============================================================
BEGIN;

INSERT INTO workflows (id, org_id, name, config, status, created_at)
SELECT
  gen_random_uuid(),
  '00000001-0000-0000-0000-000000000001'::UUID,
  'Riverside Workflow ' || s.i,
  jsonb_build_object('trigger',(ARRAY['prior_auth_approved','claim_denied','dispense_held','claim_submitted'])[1+(s.i%4)],
    'actions',jsonb_build_array('notify_provider','update_record'),'retry_limit',3,'timeout_hours',24),
  (ARRAY['active','active','active','paused','draft'])[1+(s.i%5)],
  NOW() - (random()*365)::INT * INTERVAL '1 day'
FROM generate_series(1,20) AS s(i);

INSERT INTO workflows (id, org_id, name, config, status, created_at)
SELECT
  gen_random_uuid(),
  '00000001-0000-0000-0000-000000000002'::UUID,
  'Summit Workflow ' || s.i,
  jsonb_build_object('trigger',(ARRAY['prior_auth_approved','claim_denied','dispense_held','claim_submitted'])[1+(s.i%4)],
    'actions',jsonb_build_array('notify_provider','escalate'),'retry_limit',5,'timeout_hours',48),
  (ARRAY['active','active','paused','draft','active'])[1+(s.i%5)],
  NOW() - (random()*365)::INT * INTERVAL '1 day'
FROM generate_series(1,20) AS s(i);

INSERT INTO workflows (id, org_id, name, config, status, created_at)
SELECT
  gen_random_uuid(),
  '00000001-0000-0000-0000-000000000003'::UUID,
  'Northgate Workflow ' || s.i,
  jsonb_build_object('trigger',(ARRAY['prior_auth_approved','claim_denied'])[1+(s.i%2)],
    'actions',jsonb_build_array('notify_provider'),'retry_limit',3,'timeout_hours',12),
  (ARRAY['active','paused'])[1+(s.i%2)],
  NOW() - (random()*365)::INT * INTERVAL '1 day'
FROM generate_series(1,10) AS s(i);

COMMIT;

-- ============================================================
-- WORKFLOW EVENTS  (1,000,000)
-- ============================================================

CREATE TEMP TABLE wf_ids AS
SELECT id, row_number() OVER (ORDER BY id) - 1 AS rn
FROM workflows;

CREATE INDEX ON wf_ids(rn);

BEGIN;

INSERT INTO workflow_events (id, workflow_id, patient_id, event_type, payload, created_at)
SELECT
  gen_random_uuid(),
  wf.id,
  p.id,
  (ARRAY['claim_received','auth_requested','auth_approved','auth_denied','claim_submitted',
         'claim_paid','claim_denied','dispense_triggered','patient_notified','escalated'])
    [ 1 + (s.i % 10) ],
  jsonb_build_object('sequence', s.i, 'source', 'plenful_engine',
    'duration_ms', (random()*500)::INT),
  NOW() - (random()*180)::INT * INTERVAL '1 day'
FROM generate_series(0, 999999) AS s(i)
JOIN wf_ids wf ON wf.rn = (s.i % 50)
JOIN pt     p  ON p.rn  = (s.i % 100000);

COMMIT;

\echo 'Reseed complete.'
SELECT relname, COUNT(*) FROM (
  SELECT 'claims' AS relname, COUNT(*) FROM claims
  UNION ALL SELECT 'claim_line_items', COUNT(*) FROM claim_line_items
  UNION ALL SELECT 'prior_authorizations', COUNT(*) FROM prior_authorizations
  UNION ALL SELECT 'dispensing_records', COUNT(*) FROM dispensing_records
  UNION ALL SELECT 'workflows', COUNT(*) FROM workflows
  UNION ALL SELECT 'workflow_events', COUNT(*) FROM workflow_events
) t GROUP BY relname ORDER BY relname;
