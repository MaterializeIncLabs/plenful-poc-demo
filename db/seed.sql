-- plenful-poc seed data
-- Generates realistic healthcare data at scale.
-- Targets:
--   10 organizations
--   100,000 patients
--   500,000 claims
--   ~1.25M claim line items (~2-3 per claim)
--   200,000 prior authorizations
--   150,000 dispensing records
--   ~50 workflows across 3 orgs
--   1,000,000 workflow events
--
-- Runnable as a single psql script.

-- ============================================================
-- ORGANIZATIONS
-- ============================================================
BEGIN;

INSERT INTO organizations (id, name, type, created_at)
VALUES
  ('00000001-0000-0000-0000-000000000001', 'Riverside Health System',    'health_system', NOW() - INTERVAL '3 years'),
  ('00000001-0000-0000-0000-000000000002', 'Summit Medical Group',        'health_system', NOW() - INTERVAL '3 years'),
  ('00000001-0000-0000-0000-000000000003', 'Northgate Hospital Network',  'health_system', NOW() - INTERVAL '2 years'),
  ('00000001-0000-0000-0000-000000000004', 'ClearPath Pharmacy',          'pharmacy',      NOW() - INTERVAL '2 years'),
  ('00000001-0000-0000-0000-000000000005', 'MediQuick Dispensary',        'pharmacy',      NOW() - INTERVAL '2 years'),
  ('00000001-0000-0000-0000-000000000006', 'HealthBridge Pharmacy',       'pharmacy',      NOW() - INTERVAL '1 year'),
  ('00000001-0000-0000-0000-000000000007', 'BlueStar Insurance',          'insurance',     NOW() - INTERVAL '3 years'),
  ('00000001-0000-0000-0000-000000000008', 'Apex Health Coverage',        'insurance',     NOW() - INTERVAL '3 years'),
  ('00000001-0000-0000-0000-000000000009', 'National Care Plans',         'insurance',     NOW() - INTERVAL '2 years'),
  ('00000001-0000-0000-0000-000000000010', 'Horizon Benefits Group',      'insurance',     NOW() - INTERVAL '1 year');

COMMIT;

-- ============================================================
-- PATIENTS  (100,000)
-- ============================================================
BEGIN;

INSERT INTO patients (id, org_id, mrn, attributes, created_at, updated_at)
SELECT
  gen_random_uuid(),
  (ARRAY[
    '00000001-0000-0000-0000-000000000001',
    '00000001-0000-0000-0000-000000000002',
    '00000001-0000-0000-0000-000000000003'
  ])[1 + (i % 3)]::UUID,
  'MRN-' || LPAD(i::TEXT, 7, '0'),
  jsonb_build_object(
    'insurance_id',  'INS-' || LPAD((1000000 + i)::TEXT, 8, '0'),
    'plan_type',     (ARRAY['HMO','PPO','EPO','HDHP','POS'])[ 1 + (i % 5) ],
    'dob',           (DATE '1940-01-01' + (random() * 25000)::INT)::TEXT,
    'zip',           LPAD((10000 + (i % 89999))::TEXT, 5, '0'),
    'risk_score',    round((random() * 9 + 1)::NUMERIC, 2),
    'chronic_conditions', (CASE WHEN random() < 0.3 THEN
                              jsonb_build_array('diabetes','hypertension')
                           WHEN random() < 0.5 THEN
                              jsonb_build_array('asthma')
                           ELSE
                              '[]'::JSONB
                           END),
    'preferred_pharmacy_id', '00000001-0000-0000-0000-' || LPAD((4 + (i % 3))::TEXT, 12, '0')
  ),
  NOW() - (random() * 730)::INT * INTERVAL '1 day',
  NOW() - (random() * 30)::INT  * INTERVAL '1 day'
FROM generate_series(1, 100000) AS s(i);

COMMIT;

-- Temp table for efficient patient lookups by row number (0-based)
CREATE TEMP TABLE pt AS
SELECT id, org_id, row_number() OVER (ORDER BY id) - 1 AS rn
FROM patients;
CREATE INDEX ON pt(rn);

-- ============================================================
-- CLAIMS  (500,000)
-- Status distribution: ~60% paid, ~20% pending, ~10% partial,
--                      ~5% denied, ~3% submitted, ~2% reconciled
-- ============================================================
BEGIN;

INSERT INTO claims (
  id, patient_id, org_id, payer,
  status, billed_amount, paid_amount,
  service_date, reconciled, created_at, updated_at
)
SELECT
  gen_random_uuid(),
  p.id  AS patient_id,
  p.org_id,
  (ARRAY['BlueStar Insurance','Apex Health Coverage','National Care Plans','Horizon Benefits Group','Medicare','Medicaid'])
    [ 1 + (s.i % 6) ]  AS payer,
  CASE
    WHEN s.i % 100 < 60 THEN 'paid'
    WHEN s.i % 100 < 80 THEN 'pending'
    WHEN s.i % 100 < 90 THEN 'partial'
    WHEN s.i % 100 < 95 THEN 'denied'
    WHEN s.i % 100 < 98 THEN 'submitted'
    ELSE                      'reconciled'
  END  AS status,
  round((50 + random() * 4950)::NUMERIC, 2)  AS billed_amount,
  CASE
    WHEN s.i % 100 < 60 THEN round((50 + random() * 4950)::NUMERIC * (0.7 + random() * 0.25), 2)
    WHEN s.i % 100 < 90 THEN round((50 + random() * 4950)::NUMERIC * (0.3 + random() * 0.4),  2)
    ELSE                      NULL
  END  AS paid_amount,
  (CURRENT_DATE - (random() * 365 * 2)::INT)  AS service_date,
  CASE WHEN s.i % 100 >= 98 THEN TRUE ELSE FALSE END  AS reconciled,
  NOW() - (random() * 540)::INT * INTERVAL '1 day',
  NOW() - (random() * 30)::INT  * INTERVAL '1 day'
FROM generate_series(0, 499999) AS s(i)
JOIN pt p ON p.rn = (s.i % 100000);

COMMIT;

-- ============================================================
-- CLAIM LINE ITEMS  (~1.25M — 2-3 per claim)
-- ============================================================
BEGIN;

-- First pass: 1 line item per claim (500,000)
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

-- Second pass: 1 additional line item for ~75% of claims (375,000)
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

-- Third pass: 1 additional line item for ~50% of claims (250,000) — adds detail
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
-- PRIOR AUTHORIZATIONS  (200,000)
-- ============================================================
BEGIN;

INSERT INTO prior_authorizations (
  id, patient_id, org_id,
  medication_code, status, auth_code,
  submitted_at, resolved_at, payer,
  created_at, updated_at
)
SELECT
  gen_random_uuid(),
  p.id,
  p.org_id,
  (ARRAY['J0178','J0179','J0181','J0185','J0256','J0270','J0360','J0585','J0592','J1020',
         'J1030','J1040','J1050','J1060','J1070','J1080','J1090','J1094','J1096','J1100'])
    [ 1 + (s.i % 20) ],
  CASE
    WHEN s.i % 100 < 50 THEN 'approved'
    WHEN s.i % 100 < 70 THEN 'pending'
    WHEN s.i % 100 < 85 THEN 'denied'
    ELSE                      'expired'
  END,
  CASE WHEN s.i % 100 < 50
       THEN 'AUTH-' || LPAD(s.i::TEXT, 8, '0')
       ELSE NULL
  END,
  NOW() - (random() * 365)::INT * INTERVAL '1 day',
  CASE WHEN s.i % 100 < 80
       THEN NOW() - (random() * 300)::INT * INTERVAL '1 day'
       ELSE NULL
  END,
  (ARRAY['BlueStar Insurance','Apex Health Coverage','National Care Plans','Horizon Benefits Group','Medicare','Medicaid'])
    [ 1 + (s.i % 6) ],
  NOW() - (random() * 365)::INT * INTERVAL '1 day',
  NOW() - (random() * 30)::INT  * INTERVAL '1 day'
FROM generate_series(0, 199999) AS s(i)
JOIN pt p ON p.rn = (s.i % 100000);

COMMIT;

-- Temp table for efficient prior_authorization lookups by row number (0-based)
CREATE TEMP TABLE pa_ids AS
SELECT id, medication_code, row_number() OVER (ORDER BY id) - 1 AS rn
FROM prior_authorizations;
CREATE INDEX ON pa_ids(rn);

-- ============================================================
-- DISPENSING RECORDS  (150,000)
-- ============================================================
BEGIN;

INSERT INTO dispensing_records (
  id, patient_id, org_id, prior_auth_id,
  medication_code, dispensed_at, quantity, status,
  created_at
)
SELECT
  gen_random_uuid(),
  p.id,
  -- Route to pharmacy orgs
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
JOIN pt p ON p.rn = (s.i % 100000)
JOIN pa_ids pa ON pa.rn = (s.i % 200000);

COMMIT;

-- ============================================================
-- WORKFLOWS  (~50 total across 3 orgs)
-- ============================================================
BEGIN;

-- Org 1: 20 workflows
INSERT INTO workflows (id, org_id, name, config, status, created_at)
SELECT
  gen_random_uuid(),
  '00000001-0000-0000-0000-000000000001'::UUID,
  'Riverside Workflow ' || s.i,
  jsonb_build_object(
    'trigger',       (ARRAY['prior_auth_approved','claim_denied','dispense_held','claim_submitted'])[ 1 + (s.i % 4) ],
    'actions',       jsonb_build_array('notify_provider', 'update_record'),
    'retry_limit',   3,
    'timeout_hours', 24
  ),
  (ARRAY['active','active','active','paused','draft'])[ 1 + (s.i % 5) ],
  NOW() - (random() * 365)::INT * INTERVAL '1 day'
FROM generate_series(1, 20) AS s(i);

-- Org 2: 20 workflows
INSERT INTO workflows (id, org_id, name, config, status, created_at)
SELECT
  gen_random_uuid(),
  '00000001-0000-0000-0000-000000000002'::UUID,
  'Summit Workflow ' || s.i,
  jsonb_build_object(
    'trigger',       (ARRAY['prior_auth_approved','claim_denied','dispense_held','claim_submitted'])[ 1 + (s.i % 4) ],
    'actions',       jsonb_build_array('notify_provider', 'escalate'),
    'retry_limit',   5,
    'timeout_hours', 48
  ),
  (ARRAY['active','active','paused','draft','active'])[ 1 + (s.i % 5) ],
  NOW() - (random() * 365)::INT * INTERVAL '1 day'
FROM generate_series(1, 20) AS s(i);

-- Org 3: 10 workflows
INSERT INTO workflows (id, org_id, name, config, status, created_at)
SELECT
  gen_random_uuid(),
  '00000001-0000-0000-0000-000000000003'::UUID,
  'Northgate Workflow ' || s.i,
  jsonb_build_object(
    'trigger',       (ARRAY['prior_auth_approved','claim_denied'])[ 1 + (s.i % 2) ],
    'actions',       jsonb_build_array('notify_provider'),
    'retry_limit',   3,
    'timeout_hours', 12
  ),
  (ARRAY['active','paused'])[ 1 + (s.i % 2) ],
  NOW() - (random() * 365)::INT * INTERVAL '1 day'
FROM generate_series(1, 10) AS s(i);

COMMIT;

-- Temp table for efficient workflow lookups by row number (0-based)
CREATE TEMP TABLE wf_ids AS
SELECT id, row_number() OVER (ORDER BY id) - 1 AS rn
FROM workflows;
CREATE INDEX ON wf_ids(rn);

-- ============================================================
-- WORKFLOW EVENTS  (1,000,000)
-- ============================================================
BEGIN;

INSERT INTO workflow_events (
  id, workflow_id, patient_id,
  event_type, payload, created_at
)
SELECT
  gen_random_uuid(),
  wf.id,
  p.id,
  (ARRAY[
    'prior_auth_approved',
    'claim_denied',
    'dispense_held',
    'claim_submitted',
    'auth_expiring',
    'claim_partially_paid',
    'prior_auth_pending',
    'dispense_returned'
  ])[ 1 + (s.i % 8) ],
  jsonb_build_object(
    'event_seq',      s.i,
    'severity',       (ARRAY['info','warning','critical'])[ 1 + (s.i % 3) ],
    'processed',      (s.i % 5 != 0),
    'retry_count',    (s.i % 4),
    'source_system',  (ARRAY['ehr','pharmacy','payer','clearinghouse'])[ 1 + (s.i % 4) ]
  ),
  NOW() - (random() * 365)::INT * INTERVAL '1 day'
        - (random() * 86400)::INT * INTERVAL '1 second'
FROM generate_series(0, 999999) AS s(i)
JOIN wf_ids wf ON wf.rn = (s.i % 50)
JOIN pt p ON p.rn = (s.i % 100000);

COMMIT;
