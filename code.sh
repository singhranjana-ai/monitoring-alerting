
#!/bin/bash

# Stop when an error occurs
set -Eeuo pipefail

# Check root access
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Check server architecture
if [ "$(uname -m)" != "x86_64" ]; then
    echo "This script is configured for x86_64 EC2 instances"
    exit 1
fi

# Check available disk space before installation
FREE_MB=$(df -Pm / | awk 'NR==2 {print $4}')

if [ "$FREE_MB" -lt 4000 ]; then
    echo "ERROR: At least 4 GB free disk space is required."
    echo "Please increase your root EBS volume."
    exit 1
fi

echo "Disk space check passed."

# Set software versions and AWS region
PROM_VERSION="3.15.1"
ALERT_VERSION="0.34.2"
AWS_REGION="us-east-1"

# Install basic tools
dnf install -y tar gzip

# Create temporary installation directory
WORKDIR=$(mktemp -d /tmp/monitoring-install.XXXXXX)

# Automatically remove temporary files when script exits
trap 'rm -rf "$WORKDIR"' EXIT

# ------------------------------------------------
# 1. INSTALL PROMETHEUS
# ------------------------------------------------

echo "Installing Prometheus..."

# Create Prometheus Linux user
id prometheus >/dev/null 2>&1 || \
useradd --system --no-create-home --shell /sbin/nologin prometheus

# Download Prometheus
PROM_FILE="prometheus-${PROM_VERSION}.linux-amd64.tar.gz"

curl -fL --retry 3 \
"https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_FILE}" \
-o "$WORKDIR/prometheus.tar.gz"

# Validate downloaded archive
tar -tzf "$WORKDIR/prometheus.tar.gz" >/dev/null

# Extract only required binaries
mkdir -p "$WORKDIR/prometheus"

tar -xzf "$WORKDIR/prometheus.tar.gz" \
-C "$WORKDIR/prometheus" \
--strip-components=1 \
"prometheus-${PROM_VERSION}.linux-amd64/prometheus" \
"prometheus-${PROM_VERSION}.linux-amd64/promtool"

# Install binaries
install -m 755 "$WORKDIR/prometheus/prometheus" /usr/local/bin/prometheus
install -m 755 "$WORKDIR/prometheus/promtool" /usr/local/bin/promtool

mkdir -p /etc/prometheus /var/lib/prometheus

# ------------------------------------------------
# 2. PROMETHEUS CONFIGURATION
# Discover EC2 instances using Name=node_server
# ------------------------------------------------

cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

rule_files:
  - /etc/prometheus/alert_rules.yml

scrape_configs:

  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node_server"
    ec2_sd_configs:
      - region: ${AWS_REGION}
        port: 9100
        refresh_interval: 60s
        filters:
          - name: tag:Name
            values: ["node_server"]

    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: server_name

      - source_labels: [__meta_ec2_instance_id]
        target_label: instance_id
EOF

# ------------------------------------------------
# 3. CREATE ALERT RULES
# ------------------------------------------------

cat > /etc/prometheus/alert_rules.yml <<'EOF'
groups:
  - name: node-server-alerts
    rules:

      - alert: NodeServerDown
        expr: up{job="node_server"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Node Server is down"

      - alert: HighCPUUsage
        expr: 100 * (1 - avg by (server_name, instance_id) (rate(node_cpu_seconds_total{job="node_server",mode="idle"}[5m]))) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU usage is above 80%"

      - alert: HighDiskUsage
        expr: 100 * (1 - (node_filesystem_avail_bytes{job="node_server",mountpoint="/",fstype!~"tmpfs|devtmpfs|overlay"} / node_filesystem_size_bytes{job="node_server",mountpoint="/",fstype!~"tmpfs|devtmpfs|overlay"})) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Root disk usage is above 80%"
EOF

# Set permissions
chown -R root:prometheus /etc/prometheus
chown -R prometheus:prometheus /var/lib/prometheus
chmod 750 /etc/prometheus
chmod 640 /etc/prometheus/*.yml

# Create Prometheus service
cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus Monitoring
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=3d \
  --web.listen-address=0.0.0.0:9090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Validate Prometheus configuration and alert rules
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/alert_rules.yml

# ------------------------------------------------
# 4. INSTALL ALERTMANAGER
# ------------------------------------------------

echo "Installing Alertmanager..."

# Create Alertmanager user
id alertmanager >/dev/null 2>&1 || \
useradd --system --no-create-home --shell /sbin/nologin alertmanager

# Download Alertmanager
ALERT_FILE="alertmanager-${ALERT_VERSION}.linux-amd64.tar.gz"

curl -fL --retry 3 \
"https://github.com/prometheus/alertmanager/releases/download/v${ALERT_VERSION}/${ALERT_FILE}" \
-o "$WORKDIR/alertmanager.tar.gz"

# Validate downloaded archive
tar -tzf "$WORKDIR/alertmanager.tar.gz" >/dev/null

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

mkdir -p /etc/alertmanager /var/lib/alertmanager

# Alertmanager configuration
cat > /etc/alertmanager/alertmanager.yml <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: "practice"
  group_by: ["alertname", "server_name"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: "practice"
EOF

chown root:alertmanager /etc/alertmanager
chown -R alertmanager:alertmanager /var/lib/alertmanager
chmod 750 /etc/alertmanager
chmod 640 /etc/alertmanager/alertmanager.yml

# Create Alertmanager service
cat > /etc/systemd/system/alertmanager.service <<'EOF'
[Unit]
Description=Prometheus Alertmanager
After=network-online.target
Wants=network-online.target

[Service]
User=alertmanager
Group=alertmanager
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager \
  --web.listen-address=0.0.0.0:9093
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Validate Alertmanager configuration
amtool check-config /etc/alertmanager/alertmanager.yml

# ------------------------------------------------
# 5. INSTALL GRAFANA
# ------------------------------------------------

echo "Installing Grafana..."

# Import Grafana signing key
curl -fL --retry 3 \
https://rpm.grafana.com/gpg.key \
-o "$WORKDIR/grafana.gpg.key"

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

# ------------------------------------------------
# 6. ADD PROMETHEUS AS GRAFANA DATA SOURCE
# ------------------------------------------------

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

# ------------------------------------------------
# 7. START ALL THREE SERVICES
# ------------------------------------------------

echo "Starting monitoring services..."

systemctl daemon-reload

systemctl enable --now prometheus
systemctl enable --now alertmanager
systemctl enable --now grafana-server

# ------------------------------------------------
# 8. VERIFY INSTALLATION
# ------------------------------------------------

echo ""
echo "Checking service status..."

systemctl is-active prometheus
systemctl is-active alertmanager
systemctl is-active grafana-server

echo ""
echo "======================================"
echo "MONITORING INSTALLATION COMPLETED"
echo "======================================"
echo "Prometheus:   http://SERVER-IP:9090"
echo "Grafana:      http://SERVER-IP:3000"
echo "Alertmanager: http://SERVER-IP:9093"
echo "======================================"
