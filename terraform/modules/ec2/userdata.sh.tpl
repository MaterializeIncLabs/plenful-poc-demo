#!/bin/bash
set -euo pipefail

# Install Node.js 20 and git
dnf install -y nodejs git jq aws-cli

# Get RDS credentials from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value \
  --region ${aws_region} \
  --secret-id ${rds_secret_arn} \
  --query SecretString \
  --output text)

DB_HOST=$(echo "$SECRET" | jq -r '.host')
DB_USER=$(echo "$SECRET" | jq -r '.username')
DB_PASS=$(echo "$SECRET" | jq -r '.password')
DB_NAME=$(echo "$SECRET" | jq -r '.dbname')

# Clone the repo
cd /opt
git clone https://github.com/MaterializeIncLabs/plenful-poc-demo.git app
cd app

# Write environment file
cat > /opt/app/app/.env <<EOF
DB_HOST=$DB_HOST
DB_PORT=5432
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_NAME=$DB_NAME
MZ_HOST=${mz_host}
MZ_USER=${mz_user}
MZ_PASSWORD=${mz_password}
MZ_DATABASE=${mz_database}
MZ_PORT=6875
PORT=80
EOF

# Install app dependencies
cd /opt/app/app
npm install

# Install load generator dependencies
cd /opt/app/loadgen
npm install

# Create systemd service for the app
cat > /etc/systemd/system/plenful-demo.service <<'SVCEOF'
[Unit]
Description=Plenful POC Demo App
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/app/app
EnvironmentFile=/opt/app/app/.env
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# Create systemd service for the load generator
cat > /etc/systemd/system/plenful-loadgen.service <<'SVCEOF'
[Unit]
Description=Plenful POC Load Generator
After=plenful-demo.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/app/loadgen
EnvironmentFile=/opt/app/app/.env
ExecStart=/usr/bin/node load.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable plenful-demo plenful-loadgen
systemctl start plenful-demo plenful-loadgen
