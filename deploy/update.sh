#!/bin/bash
# Quick update script for PFN MCP Server (Docker deployment)
# Run as root on the VPS

set -e

echo "=== Updating PFN MCP Server ==="

cd /opt/pfn-mcp

echo "Pulling latest changes..."
git pull

echo "Rebuilding and restarting containers..."
cd prototype
docker compose build pfn-mcp
docker compose up -d pfn-mcp mcpo

echo ""
echo "=== Update Complete ==="
docker compose ps
