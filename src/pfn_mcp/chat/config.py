"""Configuration settings for the Chat API."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class ChatSettings(BaseSettings):
    """Chat API settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    # Database
    database_url: str = "postgresql://localhost:5432/valkyrie"

    # Keycloak OAuth
    keycloak_url: str = "https://auth.forsanusa.id"
    keycloak_realm: str = "pfn"
    keycloak_client_id: str = "pfn-chat"
    keycloak_client_secret: str = ""

    # JWT settings
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 60 * 24  # 24 hours

    # Server
    chat_host: str = "0.0.0.0"
    chat_port: int = 8001

    # LLM settings (via LiteLLM)
    # Model format: provider/model or just model for Anthropic
    # Examples: "claude-sonnet-4-20250514", "minimax/MiniMax-M2", "gpt-4o"
    llm_model: str = "claude-sonnet-4-20250514"
    llm_temperature: float = 0.7
    llm_max_tokens: int = 4096

    # API keys (LiteLLM reads from env automatically)
    # ANTHROPIC_API_KEY, MINIMAX_API_KEY, OPENAI_API_KEY, etc.

    # Budget settings
    # Monthly budget per user in USD (None = unlimited)
    budget_monthly_usd: float | None = None
    # Budget period: 'monthly' or 'daily'
    budget_period: str = "monthly"
    # Warn user when budget reaches this percentage
    budget_warn_percent: float = 80.0
    # Block requests when budget reaches this percentage (None = never block)
    budget_block_percent: float | None = 100.0

    @property
    def keycloak_openid_config_url(self) -> str:
        return f"{self.keycloak_url}/realms/{self.keycloak_realm}/.well-known/openid-configuration"

    @property
    def keycloak_token_url(self) -> str:
        return f"{self.keycloak_url}/realms/{self.keycloak_realm}/protocol/openid-connect/token"

    @property
    def keycloak_auth_url(self) -> str:
        return f"{self.keycloak_url}/realms/{self.keycloak_realm}/protocol/openid-connect/auth"

    @property
    def keycloak_userinfo_url(self) -> str:
        return f"{self.keycloak_url}/realms/{self.keycloak_realm}/protocol/openid-connect/userinfo"


chat_settings = ChatSettings()
