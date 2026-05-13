# Plenful POC Demo

Split-screen demo comparing Aurora Postgres query latency vs Materialize — built for the Plenful sales POC.

---

## Prerequisites

- AWS CLI configured with credentials for the demo account
- Terraform >= 1.5
- Node.js >= 18
- `psql` client
- Materialize Cloud account (credentials in 1Password under "POC Demo")
- `gh` CLI

---

## Before first run

**1. Create the S3 bucket for Terraform state** (one-time, not managed by Terraform):

```bash
aws s3api create-bucket --bucket materialize-poc-tfstate --region us-east-1
```

**2. Copy the env template and fill in your values:**

```bash
cp .env.example .env
```

Open `.env` and fill in:
- `DB_PASS` — choose a strong password before running `terraform apply`
- `MZ_HOST` — your Materialize Cloud hostname (e.g. `abc123.us-east-1.aws.materialize.cloud`)
- `MZ_USER` — your Materialize app password username
- `MZ_PASSWORD` — your Materialize app password secret

---

## Running the demo

```bash
git clone https://github.com/MaterializeIncLabs/plenful-poc-demo
cp .env.example .env   # then fill in DB_PASS and Materialize credentials
./scripts/up.sh
```

`up.sh` provisions infrastructure, seeds the database, and prints the demo URL. The whole process takes about 10–15 minutes on first run (RDS provisioning is the slow part).

---

## Tearing down

```bash
./scripts/down.sh
```

Destroys all AWS resources. Re-seeding takes ~3 minutes on the next `up.sh`.

---

## Architecture

```
                        +---------------------------+
Browser  ------------>  |  EC2 App Server (t3.micro)|
                        +---------------------------+
                               |            |
               +---------------+            +-------------------+
               v                                                v
  +-------------------------+              +-----------------------------+
  | Aurora Postgres          |  <-- CDC --> | Materialize Cloud           |
  | (db.t3.medium)           |  replication | (25cc cluster)              |
  +-------------------------+              +-----------------------------+
```

---

## Cost

~$0.10/hour while running (~$2.40/day).

| Resource | Rate |
|----------|------|
| Aurora db.t3.medium | ~$0.082/hr |
| EC2 t3.micro | ~$0.0104/hr |
| Elastic IP (attached) | free |

**Always run `./scripts/down.sh` after demos.**

---

## Repo structure

```
plenful-poc-demo/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf
│   └── modules/
│       ├── networking/
│       ├── aurora/
│       ├── ec2/
│       └── materialize/
├── app/
│   ├── package.json
│   ├── server.js
│   └── public/
│       └── index.html
├── db/
│   ├── schema.sql
│   └── seed.sql
├── loadgen/
│   └── loadgen.js
├── scripts/
│   ├── up.sh
│   ├── down.sh
│   ├── seed.sh
│   └── status.sh
├── .env.example
├── .gitignore
├── README.md
└── RUNBOOK.md
```
