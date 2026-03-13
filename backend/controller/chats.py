from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
import logging
from database import get_db
from middleware.auth import get_current_session
from models import UserAuth
from service.chats import ChatService
from validation.chats import (
    CreateTopicSchema,
    RenameTitleSchema,
    SendMessageSchema,
    EditMessageSchema,
)

logger = logging.getLogger(__name__)
router = APIRouter(tags=["Chats"])


# =============================================================================
# HELPERS — Serializer
# =============================================================================

def _serialize_detail(d) -> dict:
    return {
        "id":         d.id,
        "chat_id":    d.chat_id,
        "question":   d.question,
        "response":   d.response,
        "created_at": d.created_at.isoformat(),
        "pipeline_log": {
            "latency_ms":    d.pipeline_log.latency_ms,
            "status":        d.pipeline_log.status,
            "input_tokens":  d.pipeline_log.input_tokens,
            "output_tokens": d.pipeline_log.output_tokens,
            "total_cost":    d.pipeline_log.total_cost,
        } if d.pipeline_log else None,
    }


def _serialize_topic(chat, include_details: bool = False) -> dict:
    data = {
        "id":         chat.id,
        "title":      chat.title,
        "created_at": chat.created_at.isoformat(),
    }
    if include_details:
        data["messages"]       = [_serialize_detail(d) for d in chat.details]
        data["total_messages"] = len(chat.details)
    return data


# =============================================================================
# TOPICS
# =============================================================================

@router.post("/topics", status_code=status.HTTP_201_CREATED)
def create_topic(
    body: CreateTopicSchema,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Buat sesi chat baru secara eksplisit.
    Gunakan endpoint ini hanya saat user klik tombol 'New Chat' di sidebar.
    Saat user pertama kali membuka app dan langsung kirim pesan,
    gunakan POST /chat/send dengan chat_id: null — topic dibuat otomatis.
    """
    try:
        chat = ChatService.create_topic(db, current_session.user_id, body.title)
        return JSONResponse(
            status_code=status.HTTP_201_CREATED,
            content={
                "success": True,
                "message": "Topik chat berhasil dibuat.",
                "data":    _serialize_topic(chat),
            },
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"POST /topics error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat membuat topik.")


@router.get("/topics", status_code=status.HTTP_200_OK)
def get_topics(
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Ambil daftar semua topik chat milik user.
    Cocok untuk sidebar — tanpa isi percakapan.
    """
    try:
        chats = ChatService.get_topics(db, current_session.user_id)
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "success": True,
                "message": "Daftar topik berhasil diambil.",
                "data": {
                    "topics": [_serialize_topic(c) for c in chats],
                    "total":  len(chats),
                },
            },
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"GET /topics error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat mengambil topik.")


@router.get("/topics/{chat_id}", status_code=status.HTTP_200_OK)
def get_topic(
    chat_id: int,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Ambil satu topik beserta seluruh isi percakapannya.
    Dipanggil saat user klik salah satu topik di sidebar.
    """
    try:
        chat = ChatService.get_topic(db, current_session.user_id, chat_id)
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "success": True,
                "message": "Topik berhasil diambil.",
                "data":    _serialize_topic(chat, include_details=True),
            },
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"GET /topics/{chat_id} error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat mengambil topik.")


@router.delete("/topics/{chat_id}", status_code=status.HTTP_200_OK)
def delete_topic(
    chat_id: int,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Hapus topik beserta seluruh isi percakapan dan pipeline log-nya (cascade).
    """
    try:
        ChatService.delete_topic(db, current_session.user_id, chat_id)
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={"success": True, "message": "Topik berhasil dihapus."},
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"DELETE /topics/{chat_id} error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat menghapus topik.")


@router.patch("/topics/{chat_id}", status_code=status.HTTP_200_OK)
def rename_topic(
    chat_id: int,
    body: RenameTitleSchema,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Ganti judul topik secara manual oleh user.
    """
    try:
        chat = ChatService.rename_topic(db, current_session.user_id, chat_id, body.title)
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "success": True,
                "message": "Judul topik berhasil diubah.",
                "data":    _serialize_topic(chat),
            },
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"PATCH /topics/{chat_id} error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat mengubah judul topik.")


# =============================================================================
# CHAT MESSAGES
# =============================================================================

@router.post("/chat/send", status_code=status.HTTP_200_OK)
def send_message(
    body: SendMessageSchema,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Kirim pertanyaan ke AI.

    - chat_id null  → topic baru dibuat otomatis dari 5 kata pertama pertanyaan.
                      Frontend simpan chat_id dari response untuk pesan berikutnya.
    - chat_id int   → lanjutkan percakapan di topic yang sudah ada.

    Response selalu menyertakan chat_id sehingga frontend tidak perlu
    hit endpoint lain untuk mengetahui ID topic yang baru dibuat.
    """
    try:
        detail = ChatService.send_message(
            db, current_session.user_id, body.chat_id, body.question
        )
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "success": True,
                "message": "Pesan berhasil dikirim.",
                "data":    _serialize_detail(detail),
            },
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"POST /chat/send error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat mengirim pesan.")


@router.patch("/chat/edit/{detail_id}", status_code=status.HTTP_200_OK)
def edit_message(
    detail_id: int,
    body: EditMessageSchema,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Edit pertanyaan yang sudah ada.
    - Update question
    - Panggil ulang LLM dengan pertanyaan baru
    - Update response dan PipelineLog di row yang sama
    """
    try:
        detail = ChatService.edit_message(
            db, current_session.user_id, detail_id, body.question
        )
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "success": True,
                "message": "Pesan berhasil diedit.",
                "data":    _serialize_detail(detail),
            },
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"PATCH /chat/edit/{detail_id} error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat mengedit pesan.")


@router.post("/chat/regenerate/{detail_id}", status_code=status.HTTP_200_OK)
def regenerate_response(
    detail_id: int,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Generate ulang jawaban AI tanpa mengubah pertanyaan.
    - Ambil question dari detail_id
    - Panggil LLM lagi
    - Update response dan PipelineLog di row yang sama
    """
    try:
        detail = ChatService.regenerate_response(
            db, current_session.user_id, detail_id
        )
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "success": True,
                "message": "Jawaban berhasil di-regenerate.",
                "data":    _serialize_detail(detail),
            },
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"POST /chat/regenerate/{detail_id} error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat regenerate jawaban.")


@router.delete("/chat/message/{detail_id}", status_code=status.HTTP_200_OK)
def delete_message(
    detail_id: int,
    db: Session = Depends(get_db),
    current_session: UserAuth = Depends(get_current_session),
):
    """
    Hapus satu baris percakapan beserta pipeline log-nya (cascade).
    """
    try:
        ChatService.delete_message(db, current_session.user_id, detail_id)
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={"success": True, "message": "Pesan berhasil dihapus."},
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        logger.error(f"DELETE /chat/message/{detail_id} error → {e}")
        raise HTTPException(status_code=500, detail="Terjadi kesalahan saat menghapus pesan.")