-- =============================================================================
-- Plenful POC — Materialize Views Reference
-- =============================================================================
-- This file is REFERENCE SQL only.
-- The actual Materialize resources (sources, connections, materialized views)
-- are managed by Terraform in terraform/modules/networking and terraform/.
--
-- You can use this file to:
--   - Understand the view definitions independently of Terraform state
--   - Run queries manually in a Materialize psql session for debugging
--   - Reproduce views if Terraform state is lost
--
-- To connect manually:
--   psql "postgres://$MZ_USER:$MZ_PASSWORD@$MZ_HOST:6875/materialize"
-- =============================================================================


-- =============================================================================
-- SOURCE CREATION (commented out — Terraform manages these)
-- =============================================================================

/*

-- Connection to Aurora Postgres via AWS PrivateLink or direct
CREATE CONNECTION aurora_pg
  TO POSTGRES (
    HOST  '<rds_endpoint>',
    PORT  5432,
    USER  '<db_user>',
    PASSWORD SECRET aurora_pg_password,
    DATABASE '<db_name>',
    SSL MODE 'require'
  );

-- Postgres source using the publication created in schema.sql
CREATE SOURCE plenful_pg
  FROM POSTGRES CONNECTION aurora_pg (
    PUBLICATION 'mz_source'
  )
  FOR ALL TABLES
  WITH (SIZE = '3xsmall');

*/


-- =============================================================================
-- MATERIALIZED VIEW 1: mv_insurance_recon
-- Purpose: Real-time insurance reconciliation — identifies claims with
--          balance discrepancies and links to prior authorization status.
-- =============================================================================

/*
CREATE MATERIALIZED VIEW mv_insurance_recon AS
*/
-- Reference query:
SELECT
  c.id                                                        AS claim_id,
  c.org_id,
  c.patient_id,
  c.payer,
  c.billed_amount,
  c.paid_amount,
  c.billed_amount - COALESCE(c.paid_amount, 0)               AS balance,
  c.status                                                    AS claim_status,
  COUNT(cli.id)                                               AS line_item_count,
  SUM(cli.billed)                                             AS total_billed,
  SUM(cli.paid)                                               AS total_paid,
  pa.status                                                   AS auth_status,
  pa.auth_code,
  c.service_date,
  c.updated_at
FROM claims c
JOIN claim_line_items cli
  ON cli.claim_id = c.id
LEFT JOIN prior_authorizations pa
  ON pa.patient_id = c.patient_id
 AND pa.status = 'approved'
WHERE c.status IN ('pending', 'partial')
GROUP BY
  c.id, c.org_id, c.patient_id, c.payer,
  c.billed_amount, c.paid_amount, c.status,
  pa.status, pa.auth_code,
  c.service_date, c.updated_at;


-- =============================================================================
-- MATERIALIZED VIEW 2: mv_patient_360
-- Purpose: Unified patient summary combining claims, authorizations,
--          and dispensing activity for a real-time 360° view.
-- =============================================================================

/*
CREATE MATERIALIZED VIEW mv_patient_360 AS
*/
-- Reference query:
SELECT
  p.id                                                        AS patient_id,
  p.org_id,
  p.mrn,
  p.attributes->>'plan_type'                                  AS plan_type,
  p.attributes->>'risk_score'                                 AS risk_score,
  p.attributes->>'zip'                                        AS zip,
  COUNT(DISTINCT c.id)                                        AS total_claims,
  SUM(c.billed_amount)                                        AS total_billed,
  SUM(c.paid_amount)                                          AS total_paid,
  COUNT(DISTINCT c.id) FILTER (WHERE c.status = 'pending')    AS pending_claims,
  COUNT(DISTINCT c.id) FILTER (WHERE c.status = 'denied')     AS denied_claims,
  COUNT(DISTINCT pa.id)                                       AS total_auths,
  COUNT(DISTINCT pa.id) FILTER (WHERE pa.status = 'approved') AS approved_auths,
  COUNT(DISTINCT pa.id) FILTER (WHERE pa.status = 'pending')  AS pending_auths,
  COUNT(DISTINCT dr.id)                                       AS total_dispenses,
  COUNT(DISTINCT dr.id) FILTER (WHERE dr.status = 'held')     AS held_dispenses,
  MAX(c.updated_at)                                           AS last_claim_update,
  MAX(dr.dispensed_at)                                        AS last_dispense
FROM patients p
LEFT JOIN claims c
  ON c.patient_id = p.id
LEFT JOIN prior_authorizations pa
  ON pa.patient_id = p.id
LEFT JOIN dispensing_records dr
  ON dr.patient_id = p.id
GROUP BY
  p.id, p.org_id, p.mrn,
  p.attributes->>'plan_type',
  p.attributes->>'risk_score',
  p.attributes->>'zip';


-- =============================================================================
-- MATERIALIZED VIEW 3: mv_dispense_exceptions
-- Purpose: Identifies dispensing records that are held or returned where
--          a corresponding approved prior authorization exists, highlighting
--          potential workflow failures.
-- =============================================================================

/*
CREATE MATERIALIZED VIEW mv_dispense_exceptions AS
*/
-- Reference query:
SELECT
  dr.id                                                       AS dispense_id,
  dr.patient_id,
  dr.org_id,
  dr.medication_code,
  dr.status                                                   AS dispense_status,
  dr.dispensed_at,
  dr.quantity,
  pa.id                                                       AS auth_id,
  pa.status                                                   AS auth_status,
  pa.auth_code,
  pa.payer,
  pa.submitted_at,
  pa.resolved_at,
  p.attributes->>'plan_type'                                  AS plan_type,
  p.attributes->>'risk_score'                                 AS risk_score
FROM dispensing_records dr
JOIN prior_authorizations pa
  ON pa.id = dr.prior_auth_id
JOIN patients p
  ON p.id = dr.patient_id
WHERE dr.status IN ('held', 'returned')
  AND pa.status = 'approved';


-- =============================================================================
-- MATERIALIZED VIEW 4: mv_workflow_summary
-- Purpose: Aggregated summary of workflow event activity per workflow,
--          broken down by event type and severity, with recency signals.
-- =============================================================================

/*
CREATE MATERIALIZED VIEW mv_workflow_summary AS
*/
-- Reference query:
SELECT
  w.id                                                        AS workflow_id,
  w.org_id,
  w.name                                                      AS workflow_name,
  w.status                                                    AS workflow_status,
  we.event_type,
  we.payload->>'severity'                                     AS severity,
  COUNT(we.id)                                                AS event_count,
  COUNT(we.id) FILTER (
    WHERE (we.payload->>'processed')::BOOLEAN = FALSE
  )                                                           AS unprocessed_count,
  MAX(we.created_at)                                          AS last_event_at,
  MIN(we.created_at)                                          AS first_event_at
FROM workflows w
JOIN workflow_events we
  ON we.workflow_id = w.id
GROUP BY
  w.id, w.org_id, w.name, w.status,
  we.event_type,
  we.payload->>'severity';


-- =============================================================================
-- MATERIALIZED VIEW 5: mv_claims_pending
-- Purpose: Real-time view of all pending and submitted claims enriched with
--          patient attributes and authorization status for triage dashboards.
-- =============================================================================

/*
CREATE MATERIALIZED VIEW mv_claims_pending AS
*/
-- Reference query:
SELECT
  c.id                                                        AS claim_id,
  c.org_id,
  c.patient_id,
  c.payer,
  c.status,
  c.billed_amount,
  c.paid_amount,
  c.billed_amount - COALESCE(c.paid_amount, 0)               AS outstanding_balance,
  c.service_date,
  c.created_at                                                AS claim_created_at,
  c.updated_at                                                AS claim_updated_at,
  NOW() - c.created_at                                        AS claim_age,
  p.mrn,
  p.attributes->>'plan_type'                                  AS plan_type,
  p.attributes->>'insurance_id'                               AS insurance_id,
  p.attributes->>'risk_score'                                 AS risk_score,
  pa.status                                                   AS auth_status,
  pa.auth_code,
  pa.payer                                                    AS auth_payer,
  COUNT(cli.id)                                               AS line_item_count
FROM claims c
JOIN patients p
  ON p.id = c.patient_id
LEFT JOIN prior_authorizations pa
  ON pa.patient_id = c.patient_id
 AND pa.status IN ('approved', 'pending')
LEFT JOIN claim_line_items cli
  ON cli.claim_id = c.id
WHERE c.status IN ('pending', 'submitted')
GROUP BY
  c.id, c.org_id, c.patient_id, c.payer,
  c.status, c.billed_amount, c.paid_amount,
  c.service_date, c.created_at, c.updated_at,
  p.mrn, p.attributes,
  pa.status, pa.auth_code, pa.payer;
