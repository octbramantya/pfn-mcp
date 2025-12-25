# PFN MCP Server

MCP server for natural language access to the Valkyrie energy monitoring database.

## Installation

```bash
pip install -e ".[dev]"
```

## Usage

```bash
pfn-mcp
```

## Configuration

Copy `.env.example` to `.env` and configure your database connection:

```bash
cp .env.example .env
```

## Development

```bash
# Run tests
pytest

# Run linter
ruff check .
```
