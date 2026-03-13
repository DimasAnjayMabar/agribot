import sys
import os
import threading
from sqlalchemy.orm import Session
from datetime import datetime
import time
import logging
from fastapi import HTTPException, status
from models import Chat, ChatDetail, PipelineLog

# Tambah root folder ke sys.path agar bisa import backend.py dari root
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
from pipeline import get_rag_pipeline

logger = logging.getLogger(__name__)


# =============================================================================
# HELPER — LLM
# =============================================================================

def _call_llm(question: str) -> dict:
    """
    Panggil RAG pipeline dan kumpulkan token streaming jadi satu string.
    Return dict berisi response, token counts, latency.
    """
    start    = time.time()
    pipeline = get_rag_pipeline()

    full_response = ""
    rag_response  = pipeline.process_query(question)

    for token in rag_response.answer:
        full_response += token

    latency_ms = int((time.time() - start) * 1000)

    return {
        "response":      full_response,
        "input_tokens":  len(question.split()),
        "output_tokens": len(full_response.split()),
        "total_cost":    0.0,
        "latency_ms":    latency_ms,
    }


def _auto_title(question: str) -> str:
    """Ambil 5 kata pertama dari pertanyaan sebagai judul otomatis."""
    words = question.strip().split()
    return " ".join(words[:5]) + ("..." if len(words) > 5 else "")


def _save_pipeline_log(
    db:           Session,
    detail_id:    int,
    llm_result:   dict,
    llm_status:   str,
    error_msg:    str | None,
    existing_log  = None,
) -> PipelineLog:
    """
    Helper buat atau update PipelineLog.
    Jika existing_log diberikan → update row yang sama.
    Jika None → buat row baru.
    """
    if existing_log:
        log = existing_log
    else:
        log = PipelineLog(chat_detail_id=detail_id)
        db.add(log)

    log.latency_ms    = llm_result["latency_ms"]
    log.status        = llm_status
    log.error_message = error_msg
    log.input_tokens  = llm_result["input_tokens"]
    log.output_tokens = llm_result["output_tokens"]
    log.total_cost    = llm_result["total_cost"]

    return log


def _invoke_llm_safe(question: str, context: str) -> tuple[dict, str, str | None]:
    """
    Panggil _call_llm dengan error handling.
    Return: (llm_result, llm_status, error_msg)
    """
    try:
        llm_result = _call_llm(question)
        return llm_result, "success", None
    except Exception as exc:
        logger.error(f"LLM call failed — {context}: {exc}")
        return {
            "response":      "Maaf, terjadi kesalahan saat memproses pertanyaan Anda.",
            "input_tokens":  0,
            "output_tokens": 0,
            "total_cost":    0.0,
            "latency_ms":    0,
        }, "failed", str(exc)


# =============================================================================
# CHAT SERVICE
# =============================================================================

class ChatService:

    # -------------------------------------------------------------------------
    # TOPICS (Chat header)
    # -------------------------------------------------------------------------

    @staticmethod
    def create_topic(db: Session, user_id: int, title: str | None = None) -> Chat:
        """
        Buat sesi chat baru secara eksplisit.
        Dipanggil hanya saat user klik tombol 'New Chat' di sidebar.
        Jika title tidak diberikan, gunakan placeholder —
        akan diganti otomatis dari 5 kata pertama saat pesan pertama dikirim.
        """
        chat = Chat(
            user_id=user_id,
            title=title or "Chat Baru",
            created_at=datetime.utcnow(),
        )
        db.add(chat)
        db.commit()
        db.refresh(chat)
        logger.info(f"Topic created → chat_id: {chat.id}, user_id: {user_id}")
        return chat

    @staticmethod
    def get_topics(db: Session, user_id: int) -> list[Chat]:
        """Ambil semua topik milik user, urut terbaru di atas."""
        return (
            db.query(Chat)
            .filter(Chat.user_id == user_id)
            .order_by(Chat.created_at.desc())
            .all()
        )

    @staticmethod
    def get_topic(db: Session, user_id: int, chat_id: int) -> Chat:
        """Ambil satu topik beserta seluruh ChatDetail-nya."""
        chat = db.query(Chat).filter(
            Chat.id == chat_id,
            Chat.user_id == user_id,
        ).first()
        if not chat:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Chat tidak ditemukan.",
            )
        return chat

    @staticmethod
    def delete_topic(db: Session, user_id: int, chat_id: int) -> bool:
        """Hapus topik + seluruh isinya (cascade delete via ORM relationship)."""
        chat = db.query(Chat).filter(
            Chat.id == chat_id,
            Chat.user_id == user_id,
        ).first()
        if not chat:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Chat tidak ditemukan.",
            )
        db.delete(chat)
        db.commit()
        logger.info(f"Topic deleted → chat_id: {chat_id}, user_id: {user_id}")
        return True

    @staticmethod
    def rename_topic(db: Session, user_id: int, chat_id: int, new_title: str) -> Chat:
        """Ganti judul chat secara manual."""
        chat = db.query(Chat).filter(
            Chat.id == chat_id,
            Chat.user_id == user_id,
        ).first()
        if not chat:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Chat tidak ditemukan.",
            )
        chat.title = new_title.strip()
        db.commit()
        db.refresh(chat)
        logger.info(f"Topic renamed → chat_id: {chat_id}, title: {chat.title}")
        return chat

    # -------------------------------------------------------------------------
    # MESSAGES (ChatDetail)
    # -------------------------------------------------------------------------

    @staticmethod
    def send_message(
        db:       Session,
        user_id:  int,
        chat_id:  int | None,
        question: str,
    ) -> ChatDetail:
        """
        Kirim pertanyaan → panggil LLM → simpan Q&A + PipelineLog sekaligus.

        Alur chat_id:
          - None  → user baru membuka app dan belum punya topic.
                    Topic baru dibuat otomatis dengan judul dari 5 kata pertama
                    pertanyaan. Frontend mendapat chat_id dari response dan
                    menyimpannya di state untuk pesan berikutnya.
          - int   → lanjutkan percakapan di topic yang sudah ada.
                    Validasi kepemilikan topic sebelum lanjut.
        """
        # ── Resolve chat (buat baru atau pakai yang ada) ──────────────────────
        if chat_id is None:
            # Auto-create topic — judul langsung dari pertanyaan pertama
            chat = Chat(
                user_id=user_id,
                title=_auto_title(question),
                created_at=datetime.utcnow(),
            )
            db.add(chat)
            db.flush()  # dapatkan chat.id tanpa commit dulu
            logger.info(
                f"Auto-create topic → chat_id: {chat.id}, "
                f"user_id: {user_id}, title: '{chat.title}'"
            )
        else:
            chat = db.query(Chat).filter(
                Chat.id == chat_id,
                Chat.user_id == user_id,
            ).first()
            if not chat:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Chat tidak ditemukan.",
                )

        # ── Panggil LLM ───────────────────────────────────────────────────────
        llm_result, llm_status, error_msg = _invoke_llm_safe(
            question, context=f"chat_id={chat.id}"
        )

        # ── Simpan ChatDetail ─────────────────────────────────────────────────
        detail = ChatDetail(
            chat_id=chat.id,
            question=question.strip(),
            response=llm_result["response"],
            created_at=datetime.utcnow(),
        )
        db.add(detail)
        db.flush()  # dapatkan detail.id sebelum commit

        # ── Simpan PipelineLog ────────────────────────────────────────────────
        _save_pipeline_log(db, detail.id, llm_result, llm_status, error_msg)

        db.commit()
        db.refresh(detail)

        logger.info(
            f"Message sent → detail_id: {detail.id}, "
            f"chat_id: {chat.id}, status: {llm_status}"
        )
        return detail

    @staticmethod
    def edit_message(
        db:           Session,
        user_id:      int,
        detail_id:    int,
        new_question: str,
    ) -> ChatDetail:
        """
        Edit pertanyaan yang sudah ada → panggil ulang LLM → update row yang sama.
        """
        detail = (
            db.query(ChatDetail)
            .join(Chat)
            .filter(ChatDetail.id == detail_id, Chat.user_id == user_id)
            .first()
        )
        if not detail:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Pesan tidak ditemukan.",
            )

        llm_result, llm_status, error_msg = _invoke_llm_safe(
            new_question, context=f"edit detail_id={detail_id}"
        )

        detail.question = new_question.strip()
        detail.response = llm_result["response"]

        _save_pipeline_log(
            db, detail.id, llm_result, llm_status, error_msg,
            existing_log=detail.pipeline_log,
        )

        db.commit()
        db.refresh(detail)
        logger.info(f"Message edited → detail_id: {detail_id}, status: {llm_status}")
        return detail

    @staticmethod
    def regenerate_response(
        db:        Session,
        user_id:   int,
        detail_id: int,
    ) -> ChatDetail:
        """
        Panggil ulang LLM dengan pertanyaan yang sama — update response saja.
        """
        detail = (
            db.query(ChatDetail)
            .join(Chat)
            .filter(ChatDetail.id == detail_id, Chat.user_id == user_id)
            .first()
        )
        if not detail:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Pesan tidak ditemukan.",
            )

        llm_result, llm_status, error_msg = _invoke_llm_safe(
            detail.question, context=f"regenerate detail_id={detail_id}"
        )

        detail.response = llm_result["response"]

        _save_pipeline_log(
            db, detail.id, llm_result, llm_status, error_msg,
            existing_log=detail.pipeline_log,
        )

        db.commit()
        db.refresh(detail)
        logger.info(f"Response regenerated → detail_id: {detail_id}, status: {llm_status}")
        return detail

    @staticmethod
    def delete_message(db: Session, user_id: int, detail_id: int) -> bool:
        """Hapus satu baris percakapan (cascade ke PipelineLog)."""
        detail = (
            db.query(ChatDetail)
            .join(Chat)
            .filter(ChatDetail.id == detail_id, Chat.user_id == user_id)
            .first()
        )
        if not detail:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Pesan tidak ditemukan.",
            )
        db.delete(detail)
        db.commit()
        logger.info(f"Message deleted → detail_id: {detail_id}")
        return True