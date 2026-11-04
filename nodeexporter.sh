
#!/bin/bash

# Install required tools
dnf install -y tar

# Create Node Exporter user
id node_exporter || useradd --system --no-create-home --shell /sbin/nologin node_exporter

# Download Node Exporter
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.12.1/node_exporter-1.12.1.linux-amd64.tar.gz

# Extract
tar -xzf node_exporter-1.12.1.linux-amd64.tar.gz

# Install binary
install -m 755 node_exporter-1.12.1.linux-amd64/node_exporter /usr/local/bin/node_exporter

# Create Node Exporter service
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Start Node Exporter
systemctl daemon-reload
systemctl enable --now node_exporter

# Verify
systemctl status node_exporter --no-pager
