from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Text, Float
from sqlalchemy.orm import relationship
from sqlalchemy.ext.declarative import declarative_base
import datetime

Base = declarative_base()

# --- 1. TABEL USER & AUTH ---
class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(50), unique=True, index=True, nullable=False)
    email = Column(String(100), unique=True, index=True, nullable=False)
    hashed_password = Column(String(255), nullable=False)
    name = Column(String(100), nullable=False)
    
    profile_image_url = Column(String(255), nullable=True)
    
    # --- Auth Management Eksplisit ---
    # Access Token disimpan agar Agent lain bisa memvalidasi secara langsung
    access_token = Column(String(255), nullable=True)
    access_token_expires_at = Column(DateTime, nullable=True)
    
    # Refresh Token untuk logika Reset Timer 2 Minggu
    refresh_token = Column(String(255), unique=True, nullable=True)
    refresh_token_expires_at = Column(DateTime, nullable=True) 
    
    last_active = Column(DateTime, default=datetime.datetime.utcnow)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    chats = relationship("Chat", back_populates="owner", cascade="all, delete-orphan")

# --- 2. TABEL CHAT (HEADER) ---
class Chat(Base):
    __tablename__ = "chats"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"))
    title = Column(Text, nullable=False) # Judul chat otomatis dari 5 kata pertama
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    # Relationships
    owner = relationship("User", back_populates="chats")
    details = relationship("ChatDetail", back_populates="chat", cascade="all, delete-orphan")


# --- 3. TABEL CHAT DETAILS (ISI PERCAKAPAN) ---
class ChatDetail(Base):
    __tablename__ = "chat_details"

    id = Column(Integer, primary_key=True, index=True)
    chat_id = Column(Integer, ForeignKey("chats.id"))
    question = Column(Text, nullable=False)
    response = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    # Relationships
    chat = relationship("Chat", back_populates="details")
    # uselist=False karena 1 pesan punya 1 log pipeline
    pipeline_log = relationship("PipelineLog", back_populates="chat_detail", uselist=False, cascade="all, delete-orphan")


# --- 4. TABEL PIPELINE LOG (MONITORING AI) ---
class PipelineLog(Base):
    __tablename__ = "pipeline_logs"

    id = Column(Integer, primary_key=True, index=True)
    chat_detail_id = Column(Integer, ForeignKey("chat_details.id"))
    
    # Metrik Performa
    latency_ms = Column(Integer) # Kecepatan respon AI dalam milidetik
    status = Column(String(20))   # 'success' atau 'failed'
    error_message = Column(Text, nullable=True)
    
    # Metrik Token (Penting jika pakai OpenAI/LLM berbayar)
    input_tokens = Column(Integer, default=0)
    output_tokens = Column(Integer, default=0)
    total_cost = Column(Float, default=0.0) # Opsional: hitung biaya API

    # Relationships
    chat_detail = relationship("ChatDetail", back_populates="pipeline_log")