#!/bin/bash
# VPS Deployment Script for PFN MCP Server
# Run as root on the VPS

set -e

echo "=== PFN MCP Server Deployment ==="

# Create user if not exists
if ! id -u pfn &>/dev/null; then
    echo "Creating pfn user..."
    useradd -r -s /bin/false pfn
fi

# Create directory
echo "Setting up /opt/pfn-mcp..."
mkdir -p /opt/pfn-mcp
cd /opt/pfn-mcp

# Clone or pull repository
if [ -d ".git" ]; then
    echo "Pulling latest changes..."
    git pull
else
    echo "Cloning repository..."
    git clone https://github.com/octbramantya/pfn-mcp.git .
fi

# Set up Python virtual environment
echo "Setting up Python environment..."
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -e .

# Copy environment file if not exists
if [ ! -f ".env" ]; then
    echo "Creating .env from production template..."
    cp deploy/.env.production .env
    echo "IMPORTANT: Review and update /opt/pfn-mcp/.env with correct credentials"
fi

# Set permissions
chown -R pfn:pfn /opt/pfn-mcp

# Install systemd service
echo "Installing systemd service..."
cp deploy/pfn-mcp.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable pfn-mcp

# Install update script
echo "Installing update script..."
cp deploy/update.sh /usr/local/bin/pfn-update
chmod +x /usr/local/bin/pfn-update

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Next steps:"
echo "  1. Review /opt/pfn-mcp/.env"
echo "  2. Start the service: systemctl start pfn-mcp"
echo "  3. Check status: systemctl status pfn-mcp"
echo "  4. View logs: journalctl -u pfn-mcp -f"
echo ""
echo "Server will be available at: http://88.222.213.96:8000"
