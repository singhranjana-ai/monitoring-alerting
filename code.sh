
#!/bin/bash

# Stop if any command fails
set -e

# Check root access
if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root"
    exit 1
fi

echo "Installing Prometheus, Grafana and Alertmanager..."

# Install required packages
dnf install -y tar gzip

# ------------------------------------------------
# 1. INSTALL PROMETHEUS
# ------------------------------------------------

# Create Prometheus user
id prometheus >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin prometheus

# Download Prometheus
cd /tmp
curl -fL -o prometheus.tar.gz \
https://github.com/prometheus/prometheus/releases/download/v3.15.1/prometheus-3.15.1.linux-amd64.tar.gz

# Extract Prometheus
tar -xzf prometheus.tar.gz

# Install binaries
install -m 755 prometheus-3.15.1.linux-amd64/prometheus /usr/local/bin/
install -m 755 prometheus-3.15.1.linux-amd64/promtool /usr/local/bin/

# Create directories
mkdir -p /etc/prometheus /var/lib/prometheus

# ------------------------------------------------
# 2. PROMETHEUS CONFIGURATION
# AWS EC2 discovery will find Name=node_server
# No fixed IP address is configured.
# ------------------------------------------------

cat > /etc/prometheus/prometheus.yml <<'EOF'
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
      - port: 9100
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
# 3. PROMETHEUS ALERT RULES
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

# Set Prometheus permissions
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
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=3d --web.listen-address=0.0.0.0:9090
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Validate Prometheus configuration
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
/usr/local/bin/promtool check rules /etc/prometheus/alert_rules.yml

# ------------------------------------------------
# 4. INSTALL ALERTMANAGER
# ------------------------------------------------

# Create Alertmanager user
id alertmanager >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin alertmanager

# Download Alertmanager
curl -fL -o alertmanager.tar.gz \
https://github.com/prometheus/alertmanager/releases/download/v0.34.2/alertmanager-0.34.2.linux-amd64.tar.gz

# Extract and install
tar -xzf alertmanager.tar.gz

install -m 755 alertmanager-0.34.2.linux-amd64/alertmanager /usr/local/bin/
install -m 755 alertmanager-0.34.2.linux-amd64/amtool /usr/local/bin/

# Create directories
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

chown -R root:alertmanager /etc/alertmanager
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
ExecStart=/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=0.0.0.0:9093
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Validate Alertmanager configuration
/usr/local/bin/amtool check-config /etc/alertmanager/alertmanager.yml

# ------------------------------------------------
# 5. INSTALL GRAFANA OSS
# ------------------------------------------------

# Import Grafana GPG key
curl -fsSL https://rpm.grafana.com/gpg.key -o /tmp/grafana.gpg.key
rpm --import /tmp/grafana.gpg.key

# Add Grafana repository
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

# Install Grafana
dnf install -y grafana

# Automatically add Prometheus as Grafana data source
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
# 6. START ALL SERVICES
# ------------------------------------------------

systemctl daemon-reload

systemctl enable --now prometheus
systemctl enable --now alertmanager
systemctl enable --now grafana-server

# ------------------------------------------------
# 7. VERIFY INSTALLATION
# ------------------------------------------------

echo "Checking service status..."

systemctl is-active prometheus
systemctl is-active alertmanager
systemctl is-active grafana-server

echo ""
echo "Installation completed successfully!"
echo "Prometheus:    http://SERVER-IP:9090"
echo "Grafana:       http://SERVER-IP:3000"
echo "Alertmanager:  http://SERVER-IP:9093"
