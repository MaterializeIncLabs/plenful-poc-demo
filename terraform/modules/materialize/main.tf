terraform {
  required_providers {
    materialize = {
      source  = "MaterializeInc/materialize"
      version = "~> 0.8"
    }
  }
}

variable "rds_host" {}
variable "rds_port" {}
variable "rds_dbname" {}
variable "rds_username" {}
variable "rds_password" { sensitive = true }

resource "materialize_cluster" "demo" {
  name               = "plenful-demo"
  size               = "25cc"
  replication_factor = 1
}

resource "materialize_secret" "pg_password" {
  name  = "pg_replication_password"
  value = var.rds_password
}

resource "materialize_connection_postgres" "aurora" {
  name     = "aurora_conn"
  host     = var.rds_host
  port     = var.rds_port
  database = var.rds_dbname
  ssl_mode = "require"

  user {
    text = var.rds_username
  }

  password {
    name          = materialize_secret.pg_password.name
    schema_name   = "public"
    database_name = "materialize"
  }
}

resource "materialize_source_postgres" "main" {
  name         = "pg_source"
  cluster_name = materialize_cluster.demo.name
  publication  = "mz_source"

  postgres_connection {
    name = materialize_connection_postgres.aurora.name
  }

  table {
    upstream_name        = "organizations"
    upstream_schema_name = "public"
    name                 = "organizations"
  }
  table {
    upstream_name        = "patients"
    upstream_schema_name = "public"
    name                 = "patients"
  }
  table {
    upstream_name        = "prior_authorizations"
    upstream_schema_name = "public"
    name                 = "prior_authorizations"
  }
  table {
    upstream_name        = "claims"
    upstream_schema_name = "public"
    name                 = "claims"
  }
  table {
    upstream_name        = "claim_line_items"
    upstream_schema_name = "public"
    name                 = "claim_line_items"
  }
  table {
    upstream_name        = "dispensing_records"
    upstream_schema_name = "public"
    name                 = "dispensing_records"
  }
  table {
    upstream_name        = "workflows"
    upstream_schema_name = "public"
    name                 = "workflows"
  }
  table {
    upstream_name        = "workflow_events"
    upstream_schema_name = "public"
    name                 = "workflow_events"
  }
}

resource "materialize_materialized_view" "insurance_recon" {
  name         = "mv_insurance_recon"
  cluster_name = materialize_cluster.demo.name

  statement = <<-SQL
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
  SQL

  depends_on = [materialize_source_postgres.main]
}

resource "materialize_materialized_view" "patient_360" {
  name         = "mv_patient_360"
  cluster_name = materialize_cluster.demo.name

  statement = <<-SQL
    SELECT
      p.id AS patient_id,
      p.org_id,
      p.mrn,
      p.attributes,
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
  SQL

  depends_on = [materialize_source_postgres.main]
}

resource "materialize_materialized_view" "dispense_exceptions" {
  name         = "mv_dispense_exceptions"
  cluster_name = materialize_cluster.demo.name

  statement = <<-SQL
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
  SQL

  depends_on = [materialize_source_postgres.main]
}

resource "materialize_materialized_view" "workflow_summary" {
  name         = "mv_workflow_summary"
  cluster_name = materialize_cluster.demo.name

  statement = <<-SQL
    SELECT
      w.org_id,
      w.id AS workflow_id,
      w.name,
      w.status,
      COUNT(we.id) AS total_events,
      COUNT(we.id) FILTER (WHERE we.created_at > mz_now() - INTERVAL '1 hour') AS events_last_hour,
      MAX(we.created_at) AS last_event_at
    FROM workflows w
    LEFT JOIN workflow_events we ON we.workflow_id = w.id
    GROUP BY w.org_id, w.id, w.name, w.status
  SQL

  depends_on = [materialize_source_postgres.main]
}

resource "materialize_materialized_view" "claims_pending" {
  name         = "mv_claims_pending"
  cluster_name = materialize_cluster.demo.name

  statement = <<-SQL
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
  SQL

  depends_on = [materialize_source_postgres.main]
}

output "cluster_name" {
  value = materialize_cluster.demo.name
}

output "source_name" {
  value = materialize_source_postgres.main.name
}
