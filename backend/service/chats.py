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
# CONSTANTS
# =============================================================================


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
_stop_events: dict[int, threading.Event] = {}
_stop_lock = threading.Lock()

def _get_stop_event(detail_id: int) -> threading.Event:
    with _stop_lock:
        if detail_id not in _stop_events:
            _stop_events[detail_id] = threading.Event()
        return _stop_events[detail_id]


def _signal_stop(detail_id: int) -> None:
    """Sinyal ke pipeline agar streaming dihentikan."""
    with _stop_lock:
        event = _stop_events.get(detail_id)
        if event:
            event.set()
            logger.info(f"Stop signal dikirim → detail_id={detail_id}")


def _cleanup_stop_event(detail_id: int) -> None:
    with _stop_lock:
        _stop_events.pop(detail_id, None)

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

def _reset_event(detail_id: int) -> asyncio.Event:
    """
    Reset asyncio.Event (SSE) dan threading.Event (stop signal).
    Dipanggil sebelum spawn thread baru untuk edit/regenerate
    agar event lama yang sudah ter-set tidak langsung trigger SSE.
    """
    with _events_lock:
        _pending_events.pop(detail_id, None)
        event = asyncio.Event()
        _pending_events[detail_id] = event

    # Reset stop event juga agar pipeline baru tidak langsung berhenti
    with _stop_lock:
        _stop_events.pop(detail_id, None)

    return event


# =============================================================================
# HELPER — LLM
# =============================================================================

def _call_llm(
    question: str,
    chat_id: int,
    user_id: int | None = None,
    stop_event: threading.Event = None,      # ← baru
) -> dict:
    start    = time.time()
    pipeline = get_rag_pipeline()

    full_response = ""
    rag_response  = pipeline.process_query(
        question,
        chat_id=chat_id,
        user_id=user_id,
        stop_event=stop_event,               # ← diteruskan ke pipeline
    )

    for token in rag_response.answer:
        # Cek stop setiap token — hentikan iterasi jika sudah di-set
        if stop_event is not None and stop_event.is_set():
            logger.info(f"[_call_llm] Stop event saat iterasi token — chat_id={chat_id}")
            break
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


def _invoke_llm_safe(
    question: str,
    chat_id: int,
    context: str,
    user_id: int | None = None,
    stop_event: threading.Event = None,      # ← baru
) -> tuple[dict, str, str | None]:
    try:
        result = _call_llm(
            question,
            chat_id=chat_id,
            user_id=user_id,
            stop_event=stop_event,           # ← diteruskan
        )
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
# BACKGROUND TASK — Memory Worker 
# =============================================================================

def _delete_memory_by_chat(chat_id: int) -> None:
    """
    Hapus semua entry memory di ChromaDB untuk chat_id tertentu.
    Mencakup dua jenis entry:
      - summary_{chat_id}        → running summary
      - recent_{chat_id}_*       → semua entry episodik (recent window)

    Dipanggil oleh delete_topic sebelum menghapus Chat dari SQL.
    Berjalan di thread pemanggil (bukan daemon) karena harus selesai
    sebelum SQL commit — urutan penting untuk konsistensi data.
    """
    try:
        pipeline  = get_rag_pipeline()
        collection = pipeline.chroma.client.get_or_create_collection("chat_memory")

        # ── Hapus running summary ─────────────────────────────────────────────
        try:
            collection.delete(ids=[f"summary_{chat_id}"])
            logger.info(f"[MemoryDelete] Summary dihapus → chat_id={chat_id}")
        except Exception:
            # Belum ada summary — tidak masalah
            logger.debug(f"[MemoryDelete] Tidak ada summary untuk chat_id={chat_id}")

        # ── Hapus semua recent entries ────────────────────────────────────────
        try:
            # Filter by id prefix — lebih reliable daripada where filter
            all_results = collection.get(include=[])
            prefix      = f"recent_{chat_id}_"
            ids_to_delete = [
                doc_id for doc_id in all_results["ids"]
                if doc_id.startswith(prefix)
            ]
            if ids_to_delete:
                collection.delete(ids=ids_to_delete)
                logger.info(
                    f"[MemoryDelete] {len(ids_to_delete)} recent entries dihapus "
                    f"→ chat_id={chat_id}"
                )
            else:
                logger.debug(
                    f"[MemoryDelete] Tidak ada recent entries untuk chat_id={chat_id}"
                )
        except Exception:
            logger.debug(
                f"[MemoryDelete] Tidak ada recent entries untuk chat_id={chat_id}"
            )

    except Exception as exc:
        # Memory delete gagal tidak boleh menghentikan delete topic
        # — log saja, lanjutkan proses
        logger.error(
            f"[MemoryDelete] Gagal hapus memory chat_id={chat_id}: {exc}",
            exc_info=True,
        )


def _delete_memory_entry(chat_id: int, detail_id: int) -> None:
    """
    Hapus satu entry recent dari ChromaDB untuk detail_id tertentu.

    Dipanggil oleh delete_message. Summary tidak disentuh — menghapus
    satu pesan tidak perlu merecalculate seluruh ringkasan.
    """
    try:
        pipeline   = get_rag_pipeline()
        collection = pipeline.chroma.client.get_or_create_collection("chat_memory")
        collection.delete(ids=[f"recent_{chat_id}_{detail_id}"])
        logger.info(
            f"[MemoryDelete] Recent entry dihapus → "
            f"chat_id={chat_id}  detail_id={detail_id}"
        )
    except Exception as exc:
        logger.error(
            f"[MemoryDelete] Gagal hapus recent entry "
            f"chat_id={chat_id}  detail_id={detail_id}: {exc}",
            exc_info=True,
        )


def _save_memory_entry(chat_id: int, detail_id: int, question: str, answer: str) -> None:
    """
    Simpan satu Q&A pair ke ChromaDB 'chat_memory' sebagai entry episodik.

    Dipanggil oleh _rag_worker setelah response berhasil di-commit ke DB.
    Berjalan di thread daemon terpisah agar tidak memblokir sinyal SSE.

    Identitas user (nama dll.) TIDAK disimpan di sini — sudah ditangani
    oleh _save_identity_entry yang dipanggil terpisah di _rag_worker.
    """
    try:
        pipeline = get_rag_pipeline()
        pipeline.save_memory(chat_id, detail_id, question, answer)
        logger.info(f"[MemorySave] Selesai → chat_id={chat_id} detail_id={detail_id}")
    except Exception as exc:
        logger.error(f"[MemorySave] Error — chat_id={chat_id}: {exc}", exc_info=True)


# =============================================================================
# BACKGROUND TASK — RAG Worker
# =============================================================================

def _rag_worker(
    detail_id: int,
    question: str,
    chat_id: int,
    db_factory,
    user_id: int,
    is_edit: bool = False,
) -> None:
    db: Session = db_factory()

    # Ambil atau buat stop event untuk detail_id ini
    stop_event = _get_stop_event(detail_id)

    try:
        from models import User
        user      = db.query(User).filter(User.id == user_id).first()
        user_name = user.name if user else None

        if user_name:
            try:
                pipeline_obj = get_rag_pipeline()
                pipeline_obj.save_identity(user_id, user_name)
            except Exception as exc:
                logger.warning(f"[Identity] Gagal simpan identity user_id={user_id}: {exc}")

        # ── Jika is_edit/regenerate → bersihkan memory lama dulu ─────────────
        if is_edit:
            try:
                pipeline_obj = get_rag_pipeline()
                collection   = pipeline_obj.chroma.client.get_or_create_collection("chat_memory")
                # Hapus summary agar tidak terkontaminasi jawaban versi sebelumnya
                collection.delete(ids=[f"summary_{chat_id}"])
                # Hapus recent entry untuk detail_id ini (akan di-upsert ulang)
                collection.delete(ids=[f"recent_{chat_id}_{detail_id}"])
                logger.info(
                    f"[MemoryReset] Summary + recent entry dihapus sebelum regenerate "
                    f"→ chat_id={chat_id}  detail_id={detail_id}"
                )
            except Exception as exc:
                logger.warning(f"[MemoryReset] Gagal hapus memory lama: {exc}")

        # ── Panggil RAG pipeline — teruskan stop_event ────────────────────────
        llm_result, llm_status, error_msg = _invoke_llm_safe(
            question,
            chat_id=chat_id,
            context=f"bg_detail_id={detail_id}",
            user_id=user_id,
            stop_event=stop_event,          # ← baru
        )

        # ── Cek apakah dihentikan oleh user ───────────────────────────────────
        was_stopped = stop_event.is_set()
        if was_stopped:
            llm_status = "stopped"
            logger.info(f"RAG worker dihentikan oleh user → detail_id={detail_id}")

        detail = db.query(ChatDetail).filter(ChatDetail.id == detail_id).first()
        if detail is None:
            logger.warning(f"RAG worker: detail_id={detail_id} tidak ditemukan di DB")
            return

        detail.response = llm_result["response"]  # simpan partial response jika ada
        detail.processing_status = (
            "stopped" if was_stopped
            else ("done" if llm_status == "success" else "failed")
        )

        existing_log = db.query(PipelineLog).filter(
            PipelineLog.chat_detail_id == detail_id
        ).first()

        _save_pipeline_log(
            db, detail_id, llm_result,
            llm_status if not was_stopped else "stopped",
            error_msg,
            existing_log=existing_log,
        )

        db.commit()
        logger.info(
            f"RAG worker selesai → detail_id={detail_id}  "
            f"chat_id={chat_id}  status={detail.processing_status}"
        )

        # ── Spawn memory save hanya jika benar-benar selesai (bukan stopped) ──
        if llm_status == "success" and not was_stopped:
            m = threading.Thread(
                target=_save_memory_entry,
                args=(chat_id, detail_id, question, llm_result["response"]),
                daemon=True,
                name=f"memory-save-{chat_id}-{detail_id}",
            )
            m.start()

    except Exception as exc:
        logger.error(f"RAG worker error — detail_id={detail_id}: {exc}")
        try:
            detail = db.query(ChatDetail).filter(ChatDetail.id == detail_id).first()
            if detail:
                detail.processing_status = "failed"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()
        _cleanup_stop_event(detail_id)
        _signal_done(detail_id)   # selalu signal SSE


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

        # Hapus memory ChromaDB lebih dulu sebelum SQL commit
        # — urutan penting agar tidak ada orphan memory jika SQL gagal
        _delete_memory_by_chat(chat_id)

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
        db_factory,
    ) -> ChatDetail:
        """
        Kirim pertanyaan ke RAG pipeline secara async.
        Langsung return ChatDetail dengan processing_status='pending'.

        Alur:
          1. Resolve atau buat topic baru (jika chat_id=None)
          2. Buat ChatDetail + PipelineLog placeholder
          3. Siapkan asyncio.Event untuk SSE
          4. Spawn _rag_worker (thread daemon) dengan chat_id
          5. Return detail — frontend polling via SSE

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

        # ── Buat ChatDetail dengan status pending ─────────────────────────────
        detail = ChatDetail(
            chat_id           = chat.id,
            question          = question.strip(),
            response          = "",
            processing_status = "pending",
            created_at        = datetime.utcnow(),
        )
        db.add(detail)
        db.flush()

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
        _get_or_create_event(detail.id)

        # ── Spawn RAG worker dengan chat_id + user_id ─────────────────────────
        t = threading.Thread(
            target=_rag_worker,
            args=(detail.id, question.strip(), chat.id, db_factory, user_id),
            daemon=True,
            name=f"rag-worker-{detail.id}",
        )
        t.start()
        logger.info(
            f"Background RAG dimulai → detail_id={detail.id}  "
            f"chat_id={chat.id}  thread={t.name}"
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
        Memory yang dipakai tetap memory chat yang sama (chat_id tidak berubah).
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

        chat_id = detail.chat_id  # simpan sebelum modifikasi

        detail.question           = new_question.strip()
        detail.response           = ""
        detail.processing_status  = "pending"
        db.commit()
        db.refresh(detail)

        _reset_event(detail.id)

        t = threading.Thread(
            target=_rag_worker,
            args=(detail.id, new_question.strip(), chat_id, db_factory, user_id),
            kwargs={"is_edit": True},
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
        """
        Regenerate → jalankan ulang RAG di background dengan question sama.
        Memory yang dipakai tetap memory chat yang sama (chat_id tidak berubah).
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

        chat_id  = detail.chat_id  # simpan sebelum modifikasi
        question = detail.question

        detail.response           = ""
        detail.processing_status  = "pending"
        db.commit()
        db.refresh(detail)

        _reset_event(detail.id)

        t = threading.Thread(
            target=_rag_worker,
            args=(detail.id, question, chat_id, db_factory, user_id),
            kwargs={"is_edit": True},
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

        chat_id = detail.chat_id  # simpan sebelum delete

        db.delete(detail)
        db.commit()
        logger.info(f"Message deleted → detail_id={detail_id}  chat_id={chat_id}")

        # Hapus recent entry dari ChromaDB setelah SQL commit berhasil
        # Summary tidak disentuh — satu pesan dihapus tidak perlu recalculate ringkasan
        _delete_memory_entry(chat_id, detail_id)

        return True
    
    @staticmethod
    def stop_generation(db: Session, user_id: int, detail_id: int) -> ChatDetail:
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
        if detail.processing_status != "pending":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Pesan tidak sedang diproses (status: {detail.processing_status}).",
            )

        _signal_stop(detail_id)
        logger.info(f"Stop diminta → detail_id={detail_id}  user_id={user_id}")
        return detail