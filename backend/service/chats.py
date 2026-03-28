import sys
import os
import threading
import asyncio
from sqlalchemy.orm import Session
from datetime import datetime
import time
import logging
from fastapi import HTTPException, status
from models import Chat, ChatDetail, PipelineLog

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
from pipeline import get_rag_pipeline

logger = logging.getLogger(__name__)


# =============================================================================
# IN-MEMORY EVENT STORE
# =============================================================================
# Menyimpan asyncio.Event per detail_id.
# Saat background task selesai → set event → SSE endpoint langsung tahu.
#
# Struktur: { detail_id: asyncio.Event }
# Event di-cleanup otomatis setelah SSE client disconnect atau timeout.

_pending_events: dict[int, asyncio.Event] = {}
_events_lock = threading.Lock()


def _get_or_create_event(detail_id: int) -> asyncio.Event:
    with _events_lock:
        if detail_id not in _pending_events:
            _pending_events[detail_id] = asyncio.Event()
        return _pending_events[detail_id]


def _signal_done(detail_id: int) -> None:
    """
    Memberikan sinyal 'done' ke event yang sedang ditunggu oleh SSE.
    Aman dipanggil dari background thread.
    """
    with _events_lock:
        event = _pending_events.get(detail_id)
        if event:
            try:
                # Ambil event loop utama yang sedang berjalan
                loop = asyncio.get_event_loop()
                # Set event secara thread-safe
                loop.call_soon_threadsafe(event.set)
            except Exception as e:
                logger.error(f"Gagal mengirim sinyal done untuk {detail_id}: {e}")
                # Fallback jika loop sulit didapat (biasanya pada shutdown)
                event.set()


def _cleanup_event(detail_id: int) -> None:
    with _events_lock:
        _pending_events.pop(detail_id, None)


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
    words = question.strip().split()
    return " ".join(words[:5]) + ("..." if len(words) > 5 else "")


def _save_pipeline_log(
    db:          Session,
    detail_id:   int,
    llm_result:  dict,
    llm_status:  str,
    error_msg:   str | None,
    existing_log = None,
) -> PipelineLog:
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
    try:
        result = _call_llm(question)
        return result, "success", None
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
# BACKGROUND TASK — RAG Worker
# =============================================================================

def _rag_worker(detail_id: int, question: str, db_factory) -> None:
    """
    Dijalankan di thread terpisah.
    1. Panggil RAG pipeline
    2. Update ChatDetail.response + processing_status di DB
    3. Simpan PipelineLog
    4. Signal asyncio.Event agar SSE endpoint tahu hasilnya sudah siap
    """
    db: Session = db_factory()
    try:
        llm_result, llm_status, error_msg = _invoke_llm_safe(
            question, context=f"bg_detail_id={detail_id}"
        )

        detail = db.query(ChatDetail).filter(ChatDetail.id == detail_id).first()
        if detail is None:
            logger.warning(f"RAG worker: detail_id={detail_id} tidak ditemukan di DB")
            return

        detail.response           = llm_result["response"]
        detail.processing_status  = "done" if llm_status == "success" else "failed"

        existing_log = db.query(PipelineLog).filter(
            PipelineLog.chat_detail_id == detail_id
        ).first()

        _save_pipeline_log(
            db, detail_id, llm_result, llm_status, error_msg,
            existing_log=existing_log,
        )

        db.commit()
        logger.info(
            f"RAG worker selesai → detail_id={detail_id}, "
            f"status={detail.processing_status}"
        )
    except Exception as exc:
        logger.error(f"RAG worker error — detail_id={detail_id}: {exc}")
        try:
            detail = db.query(ChatDetail).filter(
                ChatDetail.id == detail_id
            ).first()
            if detail:
                detail.processing_status = "failed"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()
        # Selalu signal agar SSE tidak menunggu selamanya
        _signal_done(detail_id)


# =============================================================================
# CHAT SERVICE
# =============================================================================

class ChatService:

    # -------------------------------------------------------------------------
    # TOPICS
    # -------------------------------------------------------------------------

    @staticmethod
    def create_topic(db: Session, user_id: int, title: str | None = None) -> Chat:
        chat = Chat(
            user_id=user_id,
            title=title or "Chat Baru",
            created_at=datetime.utcnow(),
        )
        db.add(chat)
        db.commit()
        db.refresh(chat)
        logger.info(f"Topic created → chat_id={chat.id}, user_id={user_id}")
        return chat

    @staticmethod
    def get_topics(db: Session, user_id: int) -> list[Chat]:
        return (
            db.query(Chat)
            .filter(Chat.user_id == user_id)
            .order_by(Chat.created_at.desc())
            .all()
        )

    @staticmethod
    def get_topic(db: Session, user_id: int, chat_id: int) -> Chat:
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
        logger.info(f"Topic deleted → chat_id={chat_id}")
        return True

    @staticmethod
    def rename_topic(db: Session, user_id: int, chat_id: int, new_title: str) -> Chat:
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
        logger.info(f"Topic renamed → chat_id={chat_id}, title={chat.title}")
        return chat

    # -------------------------------------------------------------------------
    # MESSAGES
    # -------------------------------------------------------------------------

    @staticmethod
    def send_message(
        db:          Session,
        user_id:     int,
        chat_id:     int | None,
        question:    str,
        db_factory,          # callable → Session baru untuk background thread
    ) -> ChatDetail:
        """
        Versi baru: langsung return ChatDetail dengan processing_status='pending'.
        RAG dijalankan di background thread — tidak blocking HTTP response.

        db_factory diperlukan karena SQLAlchemy Session tidak thread-safe.
        Background thread membuat Session sendiri via db_factory().
        """
        # ── Resolve atau buat topic ───────────────────────────────────────────
        if chat_id is None:
            chat = Chat(
                user_id=user_id,
                title=_auto_title(question),
                created_at=datetime.utcnow(),
            )
            db.add(chat)
            db.flush()
            logger.info(
                f"Auto-create topic → chat_id={chat.id}, title='{chat.title}'"
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

        # ── Buat ChatDetail dengan status pending — response kosong dulu ──────
        detail = ChatDetail(
            chat_id           = chat.id,
            question          = question.strip(),
            response          = "",           # diisi oleh background task
            processing_status = "pending",
            created_at        = datetime.utcnow(),
        )
        db.add(detail)
        db.flush()  # dapatkan detail.id

        # ── Buat PipelineLog placeholder ──────────────────────────────────────
        placeholder_log = PipelineLog(
            chat_detail_id = detail.id,
            latency_ms     = 0,
            status         = "pending",
            input_tokens   = 0,
            output_tokens  = 0,
            total_cost     = 0.0,
        )
        db.add(placeholder_log)

        db.commit()
        db.refresh(detail)

        # ── Siapkan event SEBELUM spawn thread ────────────────────────────────
        # Penting: event harus ada sebelum worker memanggil _signal_done
        _get_or_create_event(detail.id)

        # ── Spawn background thread untuk RAG ─────────────────────────────────
        t = threading.Thread(
            target=_rag_worker,
            args=(detail.id, question.strip(), db_factory),
            daemon=True,
            name=f"rag-worker-{detail.id}",
        )
        t.start()
        logger.info(
            f"Background RAG dimulai → detail_id={detail.id}, "
            f"chat_id={chat.id}, thread={t.name}"
        )

        return detail

    @staticmethod
    def get_detail(db: Session, user_id: int, detail_id: int) -> ChatDetail:
        """Ambil satu ChatDetail — dipakai SSE endpoint untuk baca hasil."""
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
        return detail

    @staticmethod
    def edit_message(
        db:           Session,
        user_id:      int,
        detail_id:    int,
        new_question: str,
        db_factory,
    ) -> ChatDetail:
        """
        Edit pertanyaan → jalankan ulang RAG di background.
        Langsung return detail dengan status 'pending'.
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

        detail.question           = new_question.strip()
        detail.response           = ""
        detail.processing_status  = "pending"
        db.commit()
        db.refresh(detail)

        _get_or_create_event(detail.id)

        t = threading.Thread(
            target=_rag_worker,
            args=(detail.id, new_question.strip(), db_factory),
            daemon=True,
            name=f"rag-edit-{detail.id}",
        )
        t.start()
        return detail

    @staticmethod
    def regenerate_response(
        db:        Session,
        user_id:   int,
        detail_id: int,
        db_factory,
    ) -> ChatDetail:
        """Regenerate → jalankan ulang RAG di background dengan question sama."""
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

        question                  = detail.question
        detail.response           = ""
        detail.processing_status  = "pending"
        db.commit()
        db.refresh(detail)

        _get_or_create_event(detail.id)

        t = threading.Thread(
            target=_rag_worker,
            args=(detail.id, question, db_factory),
            daemon=True,
            name=f"rag-regen-{detail.id}",
        )
        t.start()
        return detail

    @staticmethod
    def delete_message(db: Session, user_id: int, detail_id: int) -> bool:
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
        logger.info(f"Message deleted → detail_id={detail_id}")
        return True