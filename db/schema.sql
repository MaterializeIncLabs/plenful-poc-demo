-- plenful-poc schema
-- Run against Aurora Postgres before seeding

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  type TEXT CHECK (type IN ('health_system','pharmacy','insurance')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE patients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID REFERENCES organizations(id),
  mrn TEXT,
  attributes JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE prior_authorizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id UUID REFERENCES patients(id),
  org_id UUID REFERENCES organizations(id),
  medication_code TEXT,
  status TEXT CHECK (status IN ('pending','approved','denied','expired')),
  auth_code TEXT,
  submitted_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  payer TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id UUID REFERENCES patients(id),
  org_id UUID REFERENCES organizations(id),
  payer TEXT,
  status TEXT CHECK (status IN ('submitted','pending','partial','paid','denied','reconciled')),
  billed_amount NUMERIC(10,2),
  paid_amount NUMERIC(10,2),
  service_date DATE,
  reconciled BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE claim_line_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id UUID REFERENCES claims(id),
  procedure_code TEXT,
  billed NUMERIC(10,2),
  paid NUMERIC(10,2),
  status TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE dispensing_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id UUID REFERENCES patients(id),
  org_id UUID REFERENCES organizations(id),
  prior_auth_id UUID REFERENCES prior_authorizations(id),
  medication_code TEXT,
  dispensed_at TIMESTAMPTZ,
  quantity NUMERIC,
  status TEXT CHECK (status IN ('dispensed','held','returned')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE workflows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID REFERENCES organizations(id),
  name TEXT,
  config JSONB,
  status TEXT CHECK (status IN ('active','paused','draft')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE workflow_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID REFERENCES workflows(id),
  patient_id UUID REFERENCES patients(id),
  event_type TEXT,
  payload JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX ON patients(org_id);
CREATE INDEX ON patients(updated_at);
CREATE INDEX ON claims(org_id);
CREATE INDEX ON claims(status);
CREATE INDEX ON claims(updated_at);
CREATE INDEX ON claim_line_items(claim_id);
CREATE INDEX ON prior_authorizations(patient_id);
CREATE INDEX ON prior_authorizations(status);
CREATE INDEX ON dispensing_records(patient_id);
CREATE INDEX ON workflow_events(workflow_id);
CREATE INDEX ON workflow_events(created_at);

-- Required for Materialize CDC
CREATE PUBLICATION mz_source FOR ALL TABLES;
