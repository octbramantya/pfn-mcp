# PFN MCP Server - SSE Transport
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY pyproject.toml .
COPY src/ ./src/

RUN pip install --no-cache-dir .

# Default port for SSE server
EXPOSE 8000

# Run SSE server
CMD ["pfn-mcp-sse"]
