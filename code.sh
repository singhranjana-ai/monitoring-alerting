
#!/bin/bash

# ==============================================
# PROMETHEUS + GRAFANA + ALERTMANAGER + PAGERDUTY
# Monitoring server installation
# ==============================================

set -Eeuo pipefail

# Stop and report the line if any command fails
trap 'echo "ERROR: Installation failed at line $LINENO"' ERR

# Check root user
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root"
    exit 1
fi

# Check server architecture
if [ "$(uname -m)" != "x86_64" ]; then
    echo "This script requires an x86_64 EC2 instance"
    exit 1
fi

# Software versions
PROM_VERSION="3.15.1"
ALERT_VERSION="0.34.2"

# AWS region where monitoring and node servers are running
AWS_REGION="us-east-1"

echo "Starting Monitoring Stack Installation..."

# ==============================================
# STEP 1: CHECK DISK SPACE
# ==============================================

FREE_MB=$(df -Pm / | awk 'NR==2 {print $4}')

if [ "$FREE_MB" -lt 3000 ]; then
    echo "ERROR: Minimum 3 GB free disk space required."
    echo "Increase your EC2 root EBS volume and try again."
    exit 1
fi

echo "Disk space check passed."

# ==============================================
# STEP 2: INSTALL REQUIRED PACKAGES
# ==============================================

dnf install -y tar gzip

# Amazon Linux may already have curl-minimal
if ! command -v curl >/dev/null 2>&1; then
    dnf install -y curl-minimal
fi

# ==============================================
# STEP 3: GET PAGERDUTY INTEGRATION KEY
# ==============================================

echo ""
echo "Enter your PagerDuty Events API V2 Integration Key."
echo "Your key will not be displayed or stored in GitHub."

read -r -s -p "PagerDuty Integration Key: " PD_KEY
echo ""

if [ -z "$PD_KEY" ]; then
    echo "PagerDuty Integration Key is required."
    exit 1
fi

# ==============================================
# STEP 4: CREATE TEMPORARY INSTALLATION DIRECTORY
# ==============================================

WORKDIR=$(mktemp -d /tmp/monitoring.XXXXXX)

# Remove temporary installation files when script exits
trap 'rm -rf "$WORKDIR"' EXIT

# ==============================================
# STEP 5: INSTALL PROMETHEUS
# ==============================================

echo ""
echo "Installing Prometheus..."

# Create Prometheus user
id prometheus >/dev/null 2>&1 || \
useradd --system --no-create-home --shell /sbin/nologin prometheus

# Download Prometheus
PROM_FILE="prometheus-${PROM_VERSION}.linux-amd64.tar.gz"

curl -fL --retry 3 \
"https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_FILE}" \
-o "$WORKDIR/prometheus.tar.gz"

# Verify official SHA256 checksum
echo "6a726885328ad9efebbf36e876ce2fb6225468a71fd1e7ce3ba666d5f4d97a84  $WORKDIR/prometheus.tar.gz" \
| sha256sum -c -

# Extract only required Prometheus binaries
mkdir -p "$WORKDIR/prometheus"

tar -xzf "$WORKDIR/prometheus.tar.gz" \
-C "$WORKDIR/prometheus" \
--strip-components=1 \
"prometheus-${PROM_VERSION}.linux-amd64/prometheus" \
"prometheus-${PROM_VERSION}.linux-amd64/promtool"

# Install binaries
install -m 755 "$WORKDIR/prometheus/prometheus" /usr/local/bin/prometheus
install -m 755 "$WORKDIR/prometheus/promtool" /usr/local/bin/promtool

# Create Prometheus directories
mkdir -p /etc/prometheus
mkdir -p /var/lib/prometheus

# ==============================================
# STEP 6: PROMETHEUS CONFIGURATION
# AUTOMATIC AWS EC2 DISCOVERY USING NAME TAG
# ==============================================

cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "localhost:9093"

rule_files:
  - /etc/prometheus/alert_rules.yml

scrape_configs:

  # Monitor Prometheus itself
  - job_name: "prometheus"
    static_configs:
      - targets:
          - "localhost:9090"

  # Automatically discover EC2 instances
  # whose AWS Name tag is node_server

  - job_name: "node_server"

    ec2_sd_configs:
      - region: ${AWS_REGION}
        port: 9100
        refresh_interval: 60s

        filters:
          - name: tag:Name
            values:
              - node_server

          - name: instance-state-name
            values:
              - running

    relabel_configs:

      - source_labels: [__meta_ec2_tag_Name]
        target_label: server_name

      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance

      - source_labels: [__meta_ec2_instance_id]
        target_label: instance_id
EOF

# Set Prometheus permissions
chown -R root:prometheus /etc/prometheus
chown -R prometheus:prometheus /var/lib/prometheus

chmod 750 /etc/prometheus
chmod 640 /etc/prometheus/*.yml

# ==============================================
# STEP 7: CREATE PROMETHEUS ALERT RULES
# ==============================================

cat > /etc/prometheus/alert_rules.yml <<'EOF'
groups:

  - name: node-server-alerts

    rules:

      # Alert when Node Exporter is unavailable
      # Also detect when no node_server target is discovered

      - alert: NodeServerDown
        expr: up{job="node_server"} == 0 OR absent(up{job="node_server"})
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Node Server is down"
          description: "Node Server is unavailable or not discovered."

      # CPU usage above 80 percent

      - alert: HighCPUUsage
        expr: 100 * (1 - avg by (server_name, instance_id) (rate(node_cpu_seconds_total{job="node_server",mode="idle"}[5m]))) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU usage is above 80 percent"
          description: "Node Server CPU usage has exceeded 80 percent."

      # Root disk usage above 80 percent

      - alert: HighDiskUsage
        expr: 100 * (1 - (node_filesystem_avail_bytes{job="node_server",mountpoint="/",fstype!~"tmpfs|devtmpfs|overlay"} / node_filesystem_size_bytes{job="node_server",mountpoint="/",fstype!~"tmpfs|devtmpfs|overlay"})) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk usage is above 80 percent"
          description: "Node Server root disk usage has exceeded 80 percent."

EOF

# Validate Prometheus configuration
echo ""
echo "Checking Prometheus configuration..."

promtool check config /etc/prometheus/prometheus.yml

# Validate Prometheus alert rules
promtool check rules /etc/prometheus/alert_rules.yml

# ==============================================
# STEP 8: INSTALL ALERTMANAGER
# ==============================================

echo ""
echo "Installing Alertmanager..."

# Create Alertmanager user
id alertmanager >/dev/null 2>&1 || \
useradd --system --no-create-home --shell /sbin/nologin alertmanager

# Download Alertmanager
ALERT_FILE="alertmanager-${ALERT_VERSION}.linux-amd64.tar.gz"

curl -fL --retry 3 \
"https://github.com/prometheus/alertmanager/releases/download/v${ALERT_VERSION}/${ALERT_FILE}" \
-o "$WORKDIR/alertmanager.tar.gz"

# Verify official SHA256 checksum
echo "17ee14acd0f6ba6e25a436ff223d9c17ddd5cf484f543ad12f0932eaa89ba186  $WORKDIR/alertmanager.tar.gz" \
| sha256sum -c -

# Extract only required binaries
mkdir -p "$WORKDIR/alertmanager"

tar -xzf "$WORKDIR/alertmanager.tar.gz" \
-C "$WORKDIR/alertmanager" \
--strip-components=1 \
"alertmanager-${ALERT_VERSION}.linux-amd64/alertmanager" \
"alertmanager-${ALERT_VERSION}.linux-amd64/amtool"

# Install binaries
install -m 755 "$WORKDIR/alertmanager/alertmanager" /usr/local/bin/alertmanager
install -m 755 "$WORKDIR/alertmanager/amtool" /usr/local/bin/amtool

# Create Alertmanager directories
mkdir -p /etc/alertmanager
mkdir -p /var/lib/alertmanager

# Save PagerDuty key securely on EC2
printf '%s' "$PD_KEY" > /etc/alertmanager/pagerduty.key

chown alertmanager:alertmanager /etc/alertmanager/pagerduty.key
chmod 600 /etc/alertmanager/pagerduty.key

unset PD_KEY

# ==============================================
# STEP 9: ALERTMANAGER CONFIGURATION
# PAGERDUTY EVENTS API V2
# ==============================================

cat > /etc/alertmanager/alertmanager.yml <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: pagerduty
  group_by:
    - alertname
    - server_name
    - instance_id

  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:

  - name: pagerduty

    pagerduty_configs:

      - routing_key_file: /etc/alertmanager/pagerduty.key
        send_resolved: true
EOF

# Set Alertmanager permissions
chown root:alertmanager /etc/alertmanager
chown root:alertmanager /etc/alertmanager/alertmanager.yml

chmod 750 /etc/alertmanager
chmod 640 /etc/alertmanager/alertmanager.yml

# Validate Alertmanager configuration
echo ""
echo "Checking Alertmanager configuration..."

amtool check-config /etc/alertmanager/alertmanager.yml

# ==============================================
# STEP 10: CREATE ALERTMANAGER SYSTEMD SERVICE
# ==============================================

cat > /etc/systemd/system/alertmanager.service <<'EOF'
[Unit]
Description=Prometheus Alertmanager
After=network-online.target
Wants=network-online.target

[Service]
User=alertmanager
Group=alertmanager
ExecStart=/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=0.0.0.0:9093
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

chown -R alertmanager:alertmanager /var/lib/alertmanager

# ==============================================
# STEP 11: CREATE PROMETHEUS SYSTEMD SERVICE
# ==============================================

cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus Monitoring
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=3d --storage.tsdb.wal-compression --web.listen-address=0.0.0.0:9090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ==============================================
# STEP 12: INSTALL GRAFANA
# ==============================================

echo ""
echo "Installing Grafana..."

# Download Grafana GPG key
curl -fL --retry 3 \
https://rpm.grafana.com/gpg.key \
-o "$WORKDIR/grafana.gpg.key"

# Import signing key
rpm --import "$WORKDIR/grafana.gpg.key"

# Configure Grafana repository
cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
EOF

# Install Grafana OSS
dnf install -y grafana

# ==============================================
# STEP 13: ADD PROMETHEUS DATA SOURCE TO GRAFANA
# ==============================================

mkdir -p /etc/grafana/provisioning/datasources

cat > /etc/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1

datasources:

  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
EOF

chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yml
chmod 640 /etc/grafana/provisioning/datasources/prometheus.yml

# ==============================================
# STEP 14: START ALL SERVICES
# ==============================================

echo ""
echo "Starting monitoring services..."

systemctl daemon-reload

# Start Alertmanager first
systemctl enable --now alertmanager

# Start Prometheus
systemctl enable --now prometheus

# Start Grafana
systemctl enable --now grafana-server

# ==============================================
# STEP 15: VERIFY ALL SERVICES
# ==============================================

echo ""
echo "Checking service status..."

systemctl is-active prometheus
systemctl is-active alertmanager
systemctl is-active grafana-server

echo ""
echo "========================================"
echo " MONITORING STACK INSTALLED SUCCESSFULLY"
echo "========================================"

echo "Prometheus:   http://SERVER-IP:9090"
echo "Grafana:      http://SERVER-IP:3000"
echo "Alertmanager: http://SERVER-IP:9093"

echo ""
echo "Grafana initial username: admin"
echo "Grafana initial password: admin"
echo "Change password when first logging in."

echo ""
echo "PagerDuty integration configured."
echo "========================================"
