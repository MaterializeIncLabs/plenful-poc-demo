# Plenful POC Demo — Runbook

## Prerequisites
- AWS CLI configured with credentials for the materialize-demos account
- Terraform >= 1.5 installed
- Node.js >= 18 installed
- psql client installed
- Access to Materialize Cloud (credentials in 1Password under "POC Demo")
- GitHub access to MaterializeIncLabs org

## First-time setup

1. Clone the repo
   ```
   git clone https://github.com/MaterializeIncLabs/plenful-poc-demo
   cd plenful-poc-demo
   ```

2. Create the Terraform state S3 bucket (one-time, manual — not managed by Terraform)
   ```
   aws s3api create-bucket \
     --bucket materialize-poc-tfstate \
     --region us-east-1
   aws s3api put-bucket-versioning \
     --bucket materialize-poc-tfstate \
     --versioning-configuration Status=Enabled
   ```

3. Copy env template and fill in values
   ```
   cp .env.example .env
   ```
   Fill in: DB_PASS (choose a strong password), MZ_HOST, MZ_USER, MZ_PASSWORD

4. Initialize Terraform
   ```
   cd terraform && terraform init
   ```

## Turning the demo ON

```
./scripts/up.sh
```

This script:
1. Runs `terraform apply` (approx 8–12 minutes — RDS takes the longest)
2. Waits for Aurora to accept connections
3. Applies the database schema
4. Seeds the database with healthcare demo data (~3 minutes)
5. Runs a status check and prints the demo URL

Expected output:
```
==========================================
  Demo is live at: http://<elastic-ip>
  Aurora endpoint: <rds-endpoint>:5432
==========================================
```

## Turning the demo OFF

```
./scripts/down.sh
```

This script:
1. Asks for confirmation
2. Runs `terraform destroy`
3. Confirms all resources are removed

⚠️  This destroys the RDS instance and all data. Re-seeding takes ~3 minutes on next `up.sh`.

## Checking status before a demo

```
./scripts/status.sh
```

Checks:
- RDS is reachable
- Seed data is present (claims row count)
- Materialize is connected
- `mv_insurance_recon` is hydrated
- App server is responding

All checks should show `[GO]` before starting a demo.

## Running the demo

Open the demo URL in a browser (Chrome, fullscreen for presentations).

The dashboard starts automatically. Both panels show live query data within a few seconds.

### Demo talking points by control

**View selector**
Switch between views to show different query types. `insurance_recon` is the money view —
it's the equivalent of the 7-query chain that was hammering Plenful's Aurora.

**Concurrency slider (1–20)**
Drag right to add query load. Watch Aurora latency climb and buffer cache pressure build.
Around 10–12 concurrent queries the buffer hit rate drops below 50% — this is the thrashing
Swift described. Materialize stays flat at sub-5ms.

**Trigger TCS Spike button**
The money moment. Simulates the TCS team running an ad-hoc reconciliation query on prod —
creates a temp table, joins 4 tables, runs for 30 seconds. Aurora spikes. The incident banner
fires. Materialize routes the same query to `mv_insurance_recon` in <5ms.

**Query logs**
Show the actual SQL being run — real queries against the schema, not fake strings.
Postgres log shows temp table creation, lock waits, slow timings.
Materialize log shows clean sub-5ms hits against named views.

### Key numbers to call out
- Aurora at 12 concurrent queries: 3,000–8,000ms latency
- Materialize at any load: <5ms
- Buffer cache hit rate at peak load: 20–40%
- Materialize cluster size: 25cc (smallest available) — "we're not even trying hard"

## Costs while running

| Resource | Rate |
|----------|------|
| Aurora db.t3.medium | ~$0.082/hour |
| EC2 t3.micro | ~$0.0104/hour |
| Elastic IP (while attached) | free |
| Data transfer, storage | negligible |
| **Total** | **~$0.10/hour (~$2.40/day)** |

Materialize Cloud cost: depends on your tier. The demo uses the smallest cluster (25cc).

**Always run `./scripts/down.sh` after demos.**

## Troubleshooting

**"Materialize views not hydrated" / mv_insurance_recon has 0 rows**
The source takes 5–10 minutes to initial-sync on first run. Check sync status:
```sql
-- Connect to Materialize and run:
SELECT name, status, error FROM mz_sources;
```

**"RDS connection refused"**
The security group allows connections from the app server and from Materialize Cloud egress IPs.
If connecting from your laptop, temporarily add your IP to the sg-rds security group:
```
aws ec2 authorize-security-group-ingress \
  --group-id <sg-rds-id> \
  --protocol tcp --port 5432 \
  --cidr <your-ip>/32
```

**"Seed data missing"**
Re-run the seeder:
```
./scripts/seed.sh
```
To truncate and reseed:
```
./scripts/seed.sh --reset
```

**"Demo URL not loading"**
SSH to the EC2 instance:
```
ssh ec2-user@<elastic-ip>
sudo systemctl status plenful-demo
sudo journalctl -u plenful-demo -f
```

**Reseeding without destroying infrastructure**
```
./scripts/seed.sh --reset
```
Truncates all tables in FK order and reseeds. Takes ~3 minutes.

**Materialize source stuck in "starting" state**
This usually means the Aurora publication exists but the replication slot needs to be reset:
```sql
-- On Aurora:
SELECT pg_drop_replication_slot(slot_name)
FROM pg_replication_slots
WHERE slot_name LIKE 'mz_%';
-- Then in Terraform, taint the source and re-apply:
```
```
terraform taint 'module.materialize.materialize_source_postgres.main'
terraform apply ...
```
