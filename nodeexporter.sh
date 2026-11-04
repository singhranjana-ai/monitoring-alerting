
#!/bin/bash

# ============================================================
# PROJECT: AWS MONITORING AND ALERTING
# COMPONENT: NODE EXPORTER
# OS: Amazon Linux 2023
# EC2 NAME TAG: node_server
# PORT: 9100
#
# PURPOSE:
# 1. Identify EC2 using its Name tag.
# 2. Install Node Exporter.
# 3. Collect CPU, memory, disk and network metrics.
# 4. Publish EC2 identification information.
# 5. Configure systemd service.
# 6. Start Node Exporter automatically.
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# STEP 1: CHECK ROOT PERMISSION
# ------------------------------------------------------------

# Root permission is required for software installation
# and systemd configuration.

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please execute as root."
    exit 1
fi

echo "Starting Node Exporter installation..."

# ------------------------------------------------------------
# STEP 2: INSTALL REQUIRED PACKAGES
# ------------------------------------------------------------

# curl: Download files and access EC2 metadata.
# tar: Extract downloaded software.
# coreutils: Provides sha256sum and other utilities.

dnf install -y curl tar coreutils

# ------------------------------------------------------------
# STEP 3: GET EC2 METADATA TOKEN
# ------------------------------------------------------------

# AWS IMDSv2 is used to securely retrieve EC2 metadata.

TOKEN=$(curl -fsS --retry 3 -X PUT \
-H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
http://169.254.169.254/latest/api/token)

# ------------------------------------------------------------
# STEP 4: IDENTIFY EC2 INSTANCE
# ------------------------------------------------------------

# Retrieve the EC2 instance ID.

INSTANCE_ID=$(curl -fsS \
-H "X-aws-ec2-metadata-token: $TOKEN" \
http://169.254.169.254/latest/meta-data/instance-id)

# Retrieve the EC2 Name tag.
# Enable instance tags in EC2 metadata options first.

INSTANCE_NAME=$(curl -fsS \
-H "X-aws-ec2-metadata-token: $TOKEN" \
http://169.254.169.254/latest/meta-data/tags/instance/Name)

echo "Instance ID: $INSTANCE_ID"
echo "Instance Name: $INSTANCE_NAME"

# ------------------------------------------------------------
# STEP 5: VALIDATE EC2 NAME TAG
# ------------------------------------------------------------

# This installation is restricted to node_server.

if [ "$INSTANCE_NAME" != "node_server" ]; then
    echo "ERROR: EC2 Name tag must be node_server."
    exit 1
fi

echo "EC2 node_server successfully identified."

# ------------------------------------------------------------
# STEP 6: CREATE NODE EXPORTER SERVICE USER
# ------------------------------------------------------------

# Create a dedicated Linux user.
# Node Exporter should never run as root.

if ! id node_exporter >/dev/null 2>&1; then
    useradd --system --no-create-home \
    --shell /sbin/nologin node_exporter
fi

# ------------------------------------------------------------
# STEP 7: DOWNLOAD NODE EXPORTER
# ------------------------------------------------------------

VERSION="1.12.1"

cd /tmp

echo "Downloading Node Exporter version $VERSION..."

curl -fL -o node_exporter.tar.gz \
"https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz"

# ------------------------------------------------------------
# STEP 8: VERIFY SOFTWARE CHECKSUM
# ------------------------------------------------------------

# Download the official checksum file.

curl -fL -o node_exporter_checksums.txt \
"https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/sha256sums.txt"

# Verify the downloaded archive against its official checksum.

grep "node_exporter-${VERSION}.linux-amd64.tar.gz" \
node_exporter_checksums.txt | sha256sum -c -

# ------------------------------------------------------------
# STEP 9: EXTRACT NODE EXPORTER
# ------------------------------------------------------------

tar -xzf node_exporter.tar.gz

# ------------------------------------------------------------
# STEP 10: INSTALL NODE EXPORTER BINARY
# ------------------------------------------------------------

# Install the executable in /usr/local/bin.

install -o root -g root -m 0755 \
"node_exporter-${VERSION}.linux-amd64/node_exporter" \
/usr/local/bin/node_exporter

# ------------------------------------------------------------
# STEP 11: CREATE METRICS DIRECTORY
# ------------------------------------------------------------

# The textfile collector allows us to publish
# additional custom metrics, including EC2 identification.

mkdir -p /var/lib/node_exporter/textfile_collector

chown -R node_exporter:node_exporter \
/var/lib/node_exporter

# ------------------------------------------------------------
# STEP 12: CREATE EC2 IDENTIFICATION METRIC
# ------------------------------------------------------------

# Prometheus will be able to identify this EC2 instance
# through server_name=node_server.

cat > /var/lib/node_exporter/textfile_collector/ec2_info.prom <<EOF
ec2_instance_info{server_name="${INSTANCE_NAME}",instance_id="${INSTANCE_ID}"} 1
EOF

chown node_exporter:node_exporter \
/var/lib/node_exporter/textfile_collector/ec2_info.prom

chmod 0644 \
/var/lib/node_exporter/textfile_collector/ec2_info.prom

# ------------------------------------------------------------
# STEP 13: CREATE SYSTEMD SERVICE
# ------------------------------------------------------------

# systemd manages Node Exporter as a Linux service.
# Restart=always automatically restarts it after failure.
# The service starts automatically after server reboot.

cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple

ExecStart=/usr/local/bin/node_exporter \
--web.listen-address=:9100 \
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------
# STEP 14: RELOAD SYSTEMD
# ------------------------------------------------------------

# Refresh systemd to recognize the new service.

systemctl daemon-reload

# Enable service at boot and start immediately.

systemctl enable --now node_exporter

# ------------------------------------------------------------
# STEP 15: VERIFY INSTALLATION
# ------------------------------------------------------------

echo "Checking Node Exporter service..."

systemctl is-active --quiet node_exporter

# Check whether Node Exporter responds on port 9100.

curl -fsS http://localhost:9100/metrics >/dev/null

# Display EC2 identification metric.

curl -fsS http://localhost:9100/metrics \
| grep ec2_instance_info

# ------------------------------------------------------------
# INSTALLATION COMPLETED
# ------------------------------------------------------------

echo ""
echo "=============================================="
echo " NODE EXPORTER INSTALLED SUCCESSFULLY"
echo "=============================================="
echo "EC2 Name : $INSTANCE_NAME"
echo "EC2 ID   : $INSTANCE_ID"
echo "Port     : 9100"
echo "Service  : RUNNING"
echo "=============================================="

echo "Metrics URL: http://localhost:9100/metrics"
