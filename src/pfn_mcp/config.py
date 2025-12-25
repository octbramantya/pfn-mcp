"""Configuration settings for the MCP server."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    # Database connection
    database_url: str = "postgresql://localhost:5432/valkyrie"
    db_pool_min_size: int = 2
    db_pool_max_size: int = 10
    db_query_timeout: float = 30.0  # seconds

    # Server settings
    server_name: str = "pfn-mcp"
    server_version: str = "0.1.0"

    # Timezone for user-facing output
    display_timezone: str = "Asia/Jakarta"


settings = Settings()
