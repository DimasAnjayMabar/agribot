from pydantic_settings import BaseSettings, SettingsConfigDict
from functools import lru_cache
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

class Settings(BaseSettings):
    # --- Aplikasi ---
    APP_NAME: str = "AgriBot API"
    APP_ENV: str = "development"
    DEBUG: bool = True

    # --- Database ---
    DATABASE_URL: str

    # --- Email ---
    MAIL_HOST: str = "sandbox.smtp.mailtrap.io"
    MAIL_PORT: int = 587
    MAIL_USERNAME: str
    MAIL_PASSWORD: str
    MAIL_FROM: str = "noreply@agribot.com"

    # --- Tambahkan ini agar GROQ_API_KEY tidak error ---
    GROQ_API_KEY: str | None = None 

    # --- Konfigurasi V2 (Menggantikan class Config) ---
    model_config = SettingsConfigDict(
        env_file="../.env", 
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore"  # PENTING: Ini agar variabel lain di .env tidak bikin error
    )

@lru_cache
def get_settings() -> Settings:
    return Settings()

settings = get_settings()

# --- Database Engine & Session ---
engine = create_engine(settings.DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()