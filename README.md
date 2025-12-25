# PFN MCP Server

MCP server for natural language access to the Valkyrie energy monitoring database.

## Installation

```bash
pip install -e ".[dev]"
```

## Usage

### Local (stdio transport)
```bash
pfn-mcp
```

### Remote (SSE/HTTP transport)
```bash
pfn-mcp-sse
```

Server runs at `http://0.0.0.0:8000` with endpoints:
- `/` - Server info
- `/health` - Health check
- `/sse` - SSE connection for MCP
- `/messages/` - Message endpoint

## Configuration

Copy `.env.example` to `.env` and configure:

```bash
cp .env.example .env
```

Key settings:
- `DATABASE_URL` - PostgreSQL connection string
- `SERVER_HOST` / `SERVER_PORT` - SSE server binding

## Claude Desktop Configuration

For remote SSE server:
```json
{
  "mcpServers": {
    "pfn-mcp": {
      "url": "http://88.222.213.96:8000/sse"
    }
  }
}
```

## VPS Deployment

```bash
# On VPS as root
curl -sSL https://raw.githubusercontent.com/octbramantya/pfn-mcp/main/deploy/setup.sh | bash
```

Or manually:
```bash
cd /opt/pfn-mcp
git pull
.venv/bin/pip install -e .
systemctl restart pfn-mcp
```

## Development

```bash
# Run tests
pytest

# Run linter
ruff check src/
```
