#!/bin/bash
# Quick update script for PFN MCP Server
# Run as root on the VPS

set -e

echo "=== Updating PFN MCP Server ==="

cd /opt/pfn-mcp

echo "Pulling latest changes..."
git pull

echo "Installing dependencies..."
.venv/bin/pip install -e . --quiet

echo "Restarting service..."
systemctl restart pfn-mcp

echo ""
echo "=== Update Complete ==="
systemctl status pfn-mcp --no-pager
