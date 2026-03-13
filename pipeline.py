# backend.py
"""
RAG Pipeline — Struktur Baru
=============================
Alur kerja:
  1. ChromaDB  → Wide retrieval dari collection 'konten_isi'
                 Mendapat: isi_id, jurnal_id, konten_chunk
  2. Neo4j     → Context enrichment per kandidat:
                 - Node Isi (sub_judul, halaman)
                 - Node Jurnal (judul, doi, penulis, tanggal_rilis)
                 - Neighbour chunks via relasi [:NEXT]
  3. Reranking → BGE cross-encoder (CPU) menghitung skor relevansi
                 teks gabungan (prev + target + next) vs query
  4. Filtering → top-N + diversifikasi sumber (max N chunk per jurnal)
  5. LLM       → Groq API (openai/gpt-oss-120b) via streaming SSE

Hardware: Core 5 210H · 16 GB RAM · RTX 5050 8 GB VRAM
  - Embedding  → GPU/CPU  (multilingual-e5-large  ~560 MB RAM)
  - Reranker   → GPU/CPU  (bge-reranker-v2-m3     ~560 MB RAM)
  - LLM        → Groq API (tidak pakai VRAM lokal — VRAM bebas penuh)

Env vars yang dibutuhkan:
  GROQ_API_KEY  → API key Groq
"""

import os
import queue as _queue
import logging
import threading
import time
from typing import List, Dict, Optional, Generator
from dataclasses import dataclass

import torch
from groq import Groq
from sentence_transformers import SentenceTransformer, CrossEncoder
import chromadb
from chromadb.config import Settings
from neo4j import GraphDatabase
from dotenv import load_dotenv
from transformers import (
    AutoTokenizer,
    pipeline as hf_pipeline,
)

load_dotenv()

############################################################
# LOGGING SETUP
############################################################

def _setup_logger() -> logging.Logger:
    logger = logging.getLogger("agribot")
    if logger.handlers:
        return logger

    logger.setLevel(logging.DEBUG)

    GREY   = "\x1b[38;5;245m"
    CYAN   = "\x1b[36m"
    YELLOW = "\x1b[33m"
    RED    = "\x1b[31m"
    BOLD   = "\x1b[1m"
    RESET  = "\x1b[0m"

    LEVEL_COLORS = {
        logging.DEBUG:    GREY,
        logging.INFO:     CYAN,
        logging.WARNING:  YELLOW,
        logging.ERROR:    RED,
        logging.CRITICAL: BOLD + RED,
    }

    class ColorFormatter(logging.Formatter):
        def format(self, record: logging.LogRecord) -> str:
            color = LEVEL_COLORS.get(record.levelno, RESET)
            record.levelname = f"{color}{record.levelname:<8}{RESET}"
            record.name      = f"{GREY}{record.name}{RESET}"
            return super().format(record)

    console_fmt = ColorFormatter(
        fmt="%(asctime)s  %(levelname)s  %(name)s  %(message)s",
        datefmt="%H:%M:%S",
    )
    file_fmt = logging.Formatter(
        fmt="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG)
    ch.setFormatter(console_fmt)

    fh = logging.FileHandler("agribot.log", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(file_fmt)

    logger.addHandler(ch)
    logger.addHandler(fh)
    return logger


log = _setup_logger()


############################################################
# KONFIGURASI
############################################################

CONFIG = {
    # ── Model paths ──────────────────────────────────────────────────────────
    "embedding_model":   "intfloat/multilingual-e5-large",
    "reranker_model":    "BAAI/bge-reranker-v2-m3",

    # ── NLP Models (NER / token classification) ───────────────────────────────
    # IndoBERT — digunakan untuk query berbahasa Indonesia
    "nlp_id_model":      "indobenchmark/indobert-base-p1",
    # BERT multilingual — digunakan untuk query berbahasa Inggris
    "nlp_en_model":      "dslim/bert-base-NER",
    "nlp_device":        0 if torch.cuda.is_available() else -1,  # 0=GPU, -1=CPU

    # ── Hardware placement ────────────────────────────────────────────────────
    # LLM sekarang di Groq API → VRAM bebas penuh untuk embedding & reranker
    "embedding_device":  "cuda" if torch.cuda.is_available() else "cpu",
    "reranker_device":   "cuda" if torch.cuda.is_available() else "cpu",

    # ── Groq API ──────────────────────────────────────────────────────────────
    "groq_model":        "openai/gpt-oss-120b",  # model via Groq
    # GROQ_API_KEY dibaca dari environment variable — tidak di-hardcode di sini

    # ── ChromaDB — satu collection sesuai embedder baru ───────────────────────
    "chroma_path":       os.path.join(os.path.dirname(os.path.abspath(__file__)), "chroma_db"),
    "chroma_collection": "konten_isi",

    # ── Neo4j ─────────────────────────────────────────────────────────────────
    "neo4j_uri":         "neo4j://127.0.0.1:7687",
    "neo4j_user":        "neo4j",
    "neo4j_password":    "password",

    # ── Pipeline parameters ───────────────────────────────────────────────────

    # Tahap 1: berapa kandidat diambil dari ChromaDB
    "chroma_retrieval_k":    30,

    # Tahap 2: seberapa jauh window PREVIOUS/NEXT di Neo4j (1 = ±1 chunk)
    "context_window":        3,

    # Tahap 3: berapa kandidat diambil setelah reranking
    "reranked_k":            10,

    # Tahap 4: diversifikasi sumber
    "max_chunks_per_jurnal": 5,   # maksimal chunk dari satu jurnal di konteks akhir
    "final_context_k":       5,   # jumlah chunk yang masuk ke prompt LLM

    # ── LLM generation — RAG pipeline (knowledge query) ─────────────────────
    "max_new_tokens":        2048,
    "temperature":           0.2,    # rendah → faktual, deterministik
    "top_p":                 0.95,
    # Batas karakter konteks di prompt — Groq mendukung context window besar
    "context_max_chars":     24_000,  # ~6000 token × 4 char/token

    # ── LLM generation — Social pipeline (social chat) ───────────────────────
    "social_max_new_tokens": 512,    # respons sosial cukup singkat
    "social_temperature":    0.8,    # lebih tinggi → variasi & natural
    "social_top_p":          0.95,
}

############################################################
# DATA STRUCTURES
############################################################

@dataclass
class CandidateChunk:
    """Hasil dari ChromaDB wide retrieval (Tahap 1)."""
    isi_id:       str    # id Node Isi di Neo4j (kunci relasi)
    jurnal_id:    str    # id Node Jurnal
    konten_chunk: str    # teks chunk mentah
    vector_score: float  # jarak kosinus ChromaDB (lebih kecil = lebih dekat)


@dataclass
class EnrichedChunk:
    """Hasil setelah Neo4j enrichment (Tahap 2)."""
    isi_id:        str
    jurnal_id:     str
    sub_judul:     str
    halaman:       int
    konten_chunk:  str    # teks chunk TARGET (murni)
    context_text:  str    # prev + target + next (untuk reranking & LLM prompt)
    judul_jurnal:  str
    doi:           str
    penulis:       str
    tanggal_rilis: str
    vector_score:  float
    rerank_score:  float = 0.0


@dataclass
class RAGResponse:
    """Respons akhir pipeline."""
    answer:          object          # Generator[str] untuk streaming
    sources:         List[Dict]      # referensi untuk ditampilkan di UI
    final_chunks:    List[EnrichedChunk]
    processing_time: float
    intent:          str = "knowledge"  # 'knowledge' | 'social'


############################################################
# MODELS LOADER (Singleton)
############################################################

class RAGModels:
    """
    Singleton — model lokal dimuat sekali saja.

    Embedding + Reranker → GPU  (VRAM kini bebas karena LLM ada di Groq API)
    LLM                  → Groq API  (openai/gpt-oss-120b, streaming SSE)

    GROQ_API_KEY dibaca dari environment variable saat inisialisasi.
    """

    _instance = None

    @classmethod
    def reset(cls):
        """Paksa re-inisialisasi singleton — dipanggil saat module reload."""
        cls._instance = None

    def __new__(cls):
        if cls._instance is None:
            instance = super().__new__(cls)
            instance._initialize()
            cls._instance = instance
        return cls._instance

    def _initialize(self):
        log.info("Memulai pemuatan model RAG...")
        log.info(
            "Placement: embedding=%s  reranker=%s  nlp=%s  llm=groq-api(%s)",
            CONFIG["embedding_device"],
            CONFIG["reranker_device"],
            "cuda" if CONFIG["nlp_device"] >= 0 else "cpu",
            CONFIG["groq_model"],
        )

        # ── 1. Embedding model → GPU ──────────────────────────────────────────
        log.info("[1/4] Embedding: %s → %s", CONFIG["embedding_model"], CONFIG["embedding_device"])
        _t = time.perf_counter()
        self.embedding_model = SentenceTransformer(
            CONFIG["embedding_model"],
            device=CONFIG["embedding_device"],
        )
        log.info("[1/4] Embedding siap  (%.2fs)", time.perf_counter() - _t)

        # ── 2. Reranker → GPU ─────────────────────────────────────────────────
        log.info("[2/4] Reranker: %s → %s", CONFIG["reranker_model"], CONFIG["reranker_device"])
        _t = time.perf_counter()
        self.reranker = CrossEncoder(
            CONFIG["reranker_model"],
            device=CONFIG["reranker_device"],
        )
        log.info("[2/4] Reranker siap  (%.2fs)", time.perf_counter() - _t)

        # ── 3. Groq API client ────────────────────────────────────────────────
        log.info("[3/4] Groq API client → model=%s", CONFIG["groq_model"])
        api_key = os.environ.get("GROQ_API_KEY")
        if not api_key:
            raise EnvironmentError(
                "GROQ_API_KEY tidak ditemukan di environment. "
                "Set environment variable sebelum menjalankan server."
            )
        self.groq_client = Groq(api_key=api_key)
        log.info("[3/4] Groq client siap.")

        # ── 4. NLP — IndoBERT (ID) & BERT-NER (EN) ───────────────────────────
        log.info("[4/4] Memuat NLP: IndoBERT (ID) & BERT-NER (EN)...")
        _t = time.perf_counter()

        # IndoBERT — MaskedLM untuk:
        #   a) koreksi typo via fill-mask (OOV token di-mask → predict)
        #   b) ekstraksi keyword via tokenisasi sub-kata
        self.nlp_id_tokenizer = AutoTokenizer.from_pretrained(
            CONFIG["nlp_id_model"]
        )
        self.nlp_id_fillmask = hf_pipeline(
            "fill-mask",
            model=CONFIG["nlp_id_model"],
            tokenizer=CONFIG["nlp_id_model"],
            device=CONFIG["nlp_device"],
            top_k=5,   # ambil 5 kandidat per token yang di-mask
        )

        # BERT-NER — NER Inggris (dslim/bert-base-NER)
        self.nlp_en_pipeline = hf_pipeline(
            "ner",
            model=CONFIG["nlp_en_model"],
            tokenizer=CONFIG["nlp_en_model"],
            aggregation_strategy="simple",
            device=CONFIG["nlp_device"],
        )

        log.info("[4/4] NLP siap  (%.2fs)", time.perf_counter() - _t)

        log.info("✓ Semua model berhasil dimuat.")

    # ── Helpers ───────────────────────────────────────────────────────────────

    def get_embedding(self, text: str) -> List[float]:
        """Embed teks → vektor float (GPU, no_grad)."""
        with torch.no_grad():
            return self.embedding_model.encode(
                text, convert_to_tensor=False
            ).tolist()

    def rerank(self, query: str, texts: List[str]) -> List[float]:
        """
        Cross-encoder scoring (query, teks) di GPU.
        Return: list float — skor lebih tinggi = lebih relevan.
        """
        if not texts:
            return []
        pairs = [[query, t] for t in texts]
        with torch.no_grad():
            scores = self.reranker.predict(pairs)
        return scores.tolist() if hasattr(scores, "tolist") else list(scores)

    # ── Konstanta NLP ─────────────────────────────────────────────────────────

    _ID_STOPWORDS = {
        "yang", "dan", "di", "ke", "dari", "ini", "itu",
        "dengan", "untuk", "pada", "adalah", "ada", "atau",
        "juga", "oleh", "sebagai", "dalam", "tidak", "akan",
        "dapat", "bisa", "sudah", "telah", "lebih", "serta",
        "apakah", "apa", "bagaimana", "mengapa", "kenapa",
        "jelaskan", "sebutkan", "coba", "tolong", "mohon",
    }

    # Kosakata domain pertanian — TIDAK boleh dikoreksi meskipun OOV di BERT umum
    _DOMAIN_VOCAB = {
        "fusarium", "antraknosa", "nematoda", "aflatoksin", "alternaria",
        "pythium", "phytophthora", "rhizoctonia", "sclerotinia", "botrytis",
        "xanthomonas", "pseudomonas", "erwinia", "agrobacterium", "ralstonia",
        "tungro", "blas", "kresek", "hawar", "busuk", "layu", "bercak",
        "embun", "tepung", "karat", "virus", "bakteri", "jamur", "cendawan",
        "aphid", "thrips", "whitefly", "mealybug", "wereng", "penggerek",
        "ulat", "kutu", "tungau", "nematoda", "belalang", "lalat",
        # nama tanaman domain
        "kentang", "tomat", "cabai", "jagung", "padi", "kedelai", "singkong",
        "ubi", "terong", "bawang", "wortel", "kubis", "selada", "kangkung",
    }

    def correct_typo_mlm(self, text: str) -> str:
        """
        Koreksi typo pada query Bahasa Indonesia menggunakan IndoBERT MLM.

        Algoritma:
          1. Tokenisasi tiap kata dengan IndoBERT tokenizer
          2. Kata yang menghasilkan token [UNK] atau terpecah jadi ≥4 sub-kata
             dianggap berpotensi typo (OOV = out-of-vocabulary)
          3. Kata OOV yang BUKAN kosakata domain pertanian di-mask ([MASK])
          4. IndoBERT fill-mask memprediksi kandidat pengganti berdasarkan konteks
          5. Kandidat terbaik dipilih jika skornya ≥ threshold (0.15)
             dan lebih panjang dari 2 karakter (hindari prediksi noise)
          6. Hasil: query dengan kata typo sudah terkoreksi

        Catatan:
          - Kosakata domain pertanian (fusarium, antraknosa, dll) TIDAK dikoreksi
            karena memang OOV di BERT generik tapi valid secara domain
          - Threshold 0.15 cukup konservatif — hanya koreksi jika model yakin
          - Jika fill-mask gagal atau kata tidak ada kandidat baik → kata asli dipertahankan
        """
        words = text.split()
        corrected_words: list[str] = []
        any_corrected = False

        for word in words:
            word_lower = word.lower()

            # Kata domain → skip koreksi
            if word_lower in self._DOMAIN_VOCAB:
                corrected_words.append(word)
                continue

            # Cek apakah kata ini OOV di IndoBERT
            tokens = self.nlp_id_tokenizer.tokenize(word_lower)
            is_unk = "[UNK]" in tokens
            # Wordpiece memecah kata asing menjadi banyak sub-kata
            is_heavily_split = len(tokens) >= 4 and all(
                t.startswith("##") or len(t) <= 2 for t in tokens[1:]
            )

            if not (is_unk or is_heavily_split):
                # Kata dikenal dengan baik → pertahankan
                corrected_words.append(word)
                continue

            # Coba koreksi dengan fill-mask
            # Ganti kata ini dengan [MASK] dalam kalimat penuh untuk konteks
            masked_sentence = " ".join(
                "[MASK]" if w.lower() == word_lower else w
                for w in words
            )

            try:
                predictions = self.nlp_id_fillmask(masked_sentence)
                best = None
                for pred in predictions:
                    candidate = pred["token_str"].strip().lower()
                    score     = pred["score"]
                    # Filter: skor cukup tinggi, bukan noise, bukan sama persis
                    if (score >= 0.15
                            and len(candidate) > 2
                            and candidate != word_lower):
                        best = candidate
                        break

                if best:
                    log.debug(
                        "[MLM-Typo] '%s' → '%s' (score=%.3f)",
                        word, best, predictions[0]["score"],
                    )
                    corrected_words.append(best)
                    any_corrected = True
                else:
                    corrected_words.append(word)

            except Exception:
                log.warning("[MLM-Typo] fill-mask gagal untuk kata '%s'", word, exc_info=False)
                corrected_words.append(word)

        corrected_text = " ".join(corrected_words)
        if any_corrected:
            log.info("[MLM-Typo] Query terkoreksi: %r → %r", text, corrected_text)

        return corrected_text

    def extract_keywords_nlp(self, text: str, lang: str) -> str:
        """
        Ekstraksi keyword/entitas dari query menggunakan NLP:
          - lang='id' → IndoBERT: tokenisasi sub-kata, ambil token unik
                        non-stopword sebagai keyword tambahan.
          - lang='en' → BERT-NER: ambil entitas yang dikenali sebagai
                        keyword tambahan.

        Return: string keyword yang digabung ke query asli sebelum embedding,
                sehingga vektor lebih representatif terhadap entitas penting.
        """
        try:
            if lang == "id":
                tokens = self.nlp_id_tokenizer.tokenize(text)
                clean_tokens = [
                    t.replace("##", "").lower()
                    for t in tokens
                    if not t.startswith("[") and len(t.replace("##", "")) > 2
                ]
                keywords = [
                    t for t in dict.fromkeys(clean_tokens)
                    if t not in self._ID_STOPWORDS
                ]
                extra = " ".join(keywords[:10])
                log.debug("[NLP-ID] keywords: %s", extra)

            else:  # lang == 'en'
                ner_results = self.nlp_en_pipeline(text)
                keywords = list(dict.fromkeys(
                    entity["word"]
                    for entity in ner_results
                    if entity.get("score", 0) >= 0.7
                ))
                extra = " ".join(keywords[:10])
                log.debug("[NLP-EN] entities: %s", extra)

        except Exception:
            log.warning("[NLP] Ekstraksi keyword gagal, lanjut tanpa enrichment", exc_info=True)
            extra = ""

        return extra


############################################################
# TAHAP 1 — CHROMADB RETRIEVER
############################################################

class ChromaRetriever:
    """
    Wide retrieval dari ChromaDB collection 'konten_isi'.
    Metadata yang dikembalikan: isi_id (kunci ke Neo4j) + jurnal_id.
    """

    def __init__(self, persist_directory: str = CONFIG["chroma_path"]):
        log.info("ChromaDB: %s", persist_directory)
        self.client = chromadb.PersistentClient(
            path=persist_directory,
            settings=Settings(anonymized_telemetry=False),
        )
        self.collection = self.client.get_collection(CONFIG["chroma_collection"])
        log.info(
            "ChromaDB siap — '%s'  (%d dokumen)",
            CONFIG["chroma_collection"],
            self.collection.count(),
        )

    def retrieve(
        self,
        query_embedding: List[float],
        k: int = CONFIG["chroma_retrieval_k"],
    ) -> List[CandidateChunk]:
        """
        Cari k chunk paling mirip dengan query_embedding.
        Return: list CandidateChunk, urut dari yang paling dekat.
        """
        try:
            results = self.collection.query(
                query_embeddings=[query_embedding],
                n_results=k,
                include=["documents", "metadatas", "distances"],
            )
        except Exception:
            log.exception("ChromaDB query gagal (k=%d)", k)
            return []

        candidates: List[CandidateChunk] = []
        if not results["ids"] or not results["ids"][0]:
            return candidates

        for i, doc_id in enumerate(results["ids"][0]):
            meta = (results["metadatas"][0][i]
                    if results["metadatas"] and results["metadatas"][0] else {})
            dist = (float(results["distances"][0][i])
                    if results["distances"] and results["distances"][0] else 1.0)

            candidates.append(CandidateChunk(
                isi_id=meta.get("isi_id", doc_id),
                jurnal_id=meta.get("jurnal_id", ""),
                konten_chunk=results["documents"][0][i],
                vector_score=dist,
            ))

        log.debug("ChromaDB: %d kandidat ditemukan (k=%d)", len(candidates), k)
        return candidates


############################################################
# TAHAP 2 — NEO4J ENRICHER
############################################################

class Neo4jEnricher:
    """
    Context enrichment dari Neo4j per kandidat chunk.

    Per isi_id:
      - Ambil Node Isi  → sub_judul, halaman, konten_chunk
      - Ambil Node Jurnal via (Jurnal)-[:HAS_SECTION]->(Isi)
      - Ambil prev/next chunks via (Isi)-[:NEXT]->(Isi)
        sejauh context_window langkah
    """

    def __init__(
        self,
        uri:      str = CONFIG["neo4j_uri"],
        user:     str = CONFIG["neo4j_user"],
        password: str = CONFIG["neo4j_password"],
    ):
        self.driver = GraphDatabase.driver(uri, auth=(user, password))
        log.info("Neo4j: %s", uri)

    def close(self):
        self.driver.close()

    def enrich(
        self,
        candidates: List[CandidateChunk],
        context_window: int = CONFIG["context_window"],
    ) -> List[EnrichedChunk]:
        """
        Jalankan satu Cypher UNWIND untuk semua isi_id sekaligus.
        Kembalikan list EnrichedChunk dengan context_text berisi
        teks gabungan: [prev_chunks...] + target + [next_chunks...].
        """
        if not candidates:
            return []

        isi_ids  = [c.isi_id for c in candidates]
        cand_map = {c.isi_id: c for c in candidates}

        # Cypher: traverse mundur untuk prev, maju untuk next
        # Variabel {cw} diganti dengan nilai context_window
        cypher = (
            "UNWIND $isi_ids AS target_id "
            "MATCH (isi:Isi {id: target_id}) "
            "MATCH (j:Jurnal)-[:HAS_SECTION]->(isi) "

            # prev: node yang mengarah ke isi via NEXT (arah balik)
            "OPTIONAL MATCH (prev_isi:Isi)-[:NEXT*1..%(cw)d]->(isi) "
            "WITH isi, j, target_id, "
            "     collect(DISTINCT prev_isi.konten_chunk) AS prev_chunks "

            # next: node yang isi arahkan via NEXT
            "OPTIONAL MATCH (isi)-[:NEXT*1..%(cw)d]->(next_isi:Isi) "
            "WITH isi, j, target_id, prev_chunks, "
            "     collect(DISTINCT next_isi.konten_chunk) AS next_chunks "

            "RETURN "
            "  target_id        AS isi_id, "
            "  j.id             AS jurnal_id, "
            "  isi.sub_judul    AS sub_judul, "
            "  isi.halaman      AS halaman, "
            "  isi.konten_chunk AS konten_chunk, "
            "  j.judul          AS judul_jurnal, "
            "  j.doi            AS doi, "
            "  j.penulis        AS penulis, "
            "  j.tanggal_rilis  AS tanggal_rilis, "
            "  prev_chunks      AS prev_chunks, "
            "  next_chunks      AS next_chunks"
        ) % {"cw": context_window}

        enriched: List[EnrichedChunk] = []

        try:
            with self.driver.session() as session:
                for rec in session.run(cypher, isi_ids=isi_ids):
                    isi_id = rec["isi_id"]
                    cand   = cand_map.get(isi_id)
                    if cand is None:
                        continue

                    prev_list = [t for t in (rec["prev_chunks"] or []) if t]
                    next_list = [t for t in (rec["next_chunks"] or []) if t]
                    target    = rec["konten_chunk"] or ""

                    # Gabung: prev (urut maju) + target + next
                    context_text = " ".join([*prev_list, target, *next_list]).strip()

                    enriched.append(EnrichedChunk(
                        isi_id=isi_id,
                        jurnal_id=rec["jurnal_id"] or cand.jurnal_id,
                        sub_judul=rec["sub_judul"] or "Unknown",
                        halaman=int(rec["halaman"] or 0),
                        konten_chunk=target,
                        context_text=context_text,
                        judul_jurnal=rec["judul_jurnal"] or "Unknown",
                        doi=rec["doi"] or "",
                        penulis=rec["penulis"] or "Unknown",
                        tanggal_rilis=rec["tanggal_rilis"] or "Unknown",
                        vector_score=cand.vector_score,
                    ))

        except Exception:
            log.exception("Neo4j enrichment gagal (%d isi_id)", len(isi_ids))

        log.debug(
            "Neo4j enrich: %d/%d berhasil diperkaya",
            len(enriched), len(candidates),
        )
        return enriched


############################################################
# PIPELINE UTAMA — ROUTER + 2 JALUR TERPISAH
############################################################

class RAGPipeline:
    """
    Orkestrasi dua pipeline terpisah:

    ┌─────────────────────────────────────────────────────────┐
    │  process_query()  ←  router via _detect_query_intent()  │
    └───────────┬─────────────────────────┬───────────────────┘
                │ intent='knowledge'       │ intent='social'
                ▼                         ▼
    process_knowledge_query()    process_social_query()
      Tahap 1: ChromaDB            Prompt minimal → LLM
      Tahap 2: Neo4j enrich        temperature=0.8 (natural)
      Tahap 3: BGE reranking       max_new_tokens=128
      Tahap 4: Filtering
      Tahap 5: LLM (temp=0.2)
    """

    def __init__(self):
        log.info("Menginisialisasi RAGPipeline...")
        self.models = RAGModels()
        self.chroma = ChromaRetriever()
        self.neo4j  = Neo4jEnricher()
        log.info("✓ RAGPipeline siap.")

    def close(self):
        self.neo4j.close()

    # ── Public API — Router ───────────────────────────────────────────────────

    def process_query(
        self,
        query:      str,
        stop_event: threading.Event = None,
    ) -> RAGResponse:
        """
        Entry point utama. Deteksi intent lalu delegasikan ke pipeline
        yang sesuai: knowledge → process_knowledge_query,
                     social    → process_social_query.

        Sebelum deteksi intent, query Bahasa Indonesia dikoreksi typo-nya
        terlebih dahulu menggunakan IndoBERT MLM (fill-mask).
        """
        # ── Koreksi typo via IndoBERT MLM (hanya untuk query Bahasa Indonesia) ─
        lang_pre = self._detect_language(query)
        if lang_pre == "id":
            query = self.models.correct_typo_mlm(query)

        intent = self._detect_query_intent(query)
        log.info("Intent terdeteksi: %s — query=%r", intent, query[:80])

        if intent == "social":
            return self.process_social_query(query, stop_event=stop_event)
        return self.process_knowledge_query(query, stop_event=stop_event)

    # ── Social Pipeline ───────────────────────────────────────────────────────

    def process_social_query(
        self,
        query:      str,
        stop_event: threading.Event = None,
    ) -> RAGResponse:
        """
        Pipeline social — pure LLM dengan few-shot prompting via Groq API.

        Menggunakan format messages OpenAI-style dengan system role
        yang berisi persona + few-shot examples, sehingga model langsung
        tahu pola output yang diharapkan.
        """
        t_start = time.perf_counter()
        lang    = self._detect_language(query)

        if lang == "id":
            system_msg = (
                "Kamu adalah Agribot, asisten pertanian yang ramah dan santai. "
                "Balas percakapan sosial dengan singkat, hangat, dan natural dalam Bahasa Indonesia. "
                "Jangan sebut tanaman atau pertanian kecuali diminta pengguna.\n\n"
                "Contoh percakapan:\n"
                "Pengguna: halo\n"
                "Agribot: Halo! Bagaimana bisa saya membantu Anda hari ini?\n\n"
                "Pengguna: apa kabar?\n"
                "Agribot: Alhamdulillah baik, terima kasih sudah bertanya! Bagaimana dengan Anda?\n\n"
                "Pengguna: terima kasih\n"
                "Agribot: Sama-sama! Senang bisa membantu. Jangan ragu bertanya lagi ya.\n\n"
                "Pengguna: selamat tinggal\n"
                "Agribot: Selamat tinggal! Semoga hari Anda menyenangkan.\n\n"
                "Pengguna: maaf mengganggu\n"
                "Agribot: Tidak mengganggu sama sekali! Ada yang bisa saya bantu?"
            )
        else:
            system_msg = (
                "You are Agribot, a friendly farming assistant. "
                "Reply to casual social messages briefly and naturally in English. "
                "Do not mention plants or farming unless the user asks.\n\n"
                "Example conversations:\n"
                "User: hello\n"
                "Agribot: Hello! How can I help you today?\n\n"
                "User: how are you?\n"
                "Agribot: I'm doing great, thanks for asking! How about you?\n\n"
                "User: thank you\n"
                "Agribot: You're welcome! Feel free to ask anytime.\n\n"
                "User: goodbye\n"
                "Agribot: Goodbye! Have a wonderful day.\n\n"
                "User: sorry to bother you\n"
                "Agribot: Not a bother at all! What can I help you with?"
            )

        messages = [
            {"role": "system", "content": system_msg},
            {"role": "user",   "content": query},
        ]

        log.info("[Social] Groq few-shot — lang=%s  query=%r", lang, query[:60])

        answer_gen = self._generate_stream(
            messages,
            stop_event=stop_event,
            temperature=CONFIG["social_temperature"],
            top_p=CONFIG["social_top_p"],
            max_new_tokens=CONFIG["social_max_new_tokens"],
        )

        elapsed = time.perf_counter() - t_start
        return RAGResponse(
            answer=answer_gen,
            sources=[],
            final_chunks=[],
            processing_time=elapsed,
            intent="social",
        )

    # ── Knowledge Pipeline ────────────────────────────────────────────────────

    def process_knowledge_query(
        self,
        query:      str,
        stop_event: threading.Event = None,
    ) -> RAGResponse:
        """
        Pipeline knowledge — WITH retrieval (5 tahap penuh).
          Tahap 1 → ChromaDB wide retrieval
          Tahap 2 → Neo4j context enrichment
          Tahap 3 → BGE reranking (CPU)
          Tahap 4 → Filtering & diversifikasi sumber
          Tahap 5 → LLM streaming generation (GPU, temp=0.2)
        """
        t_start = time.perf_counter()
        log.info("═" * 60)
        log.info("[Knowledge] Query: %r", query[:120])

        # ── Deteksi bahasa & NLP keyword enrichment ───────────────────────────
        lang = self._detect_language(query)
        log.info("[Knowledge] Bahasa terdeteksi: %s", lang)

        nlp_keywords = self.models.extract_keywords_nlp(query, lang)
        # Query diperkaya: teks asli + keyword NLP → vektor embedding lebih akurat
        enriched_query = f"{query} {nlp_keywords}".strip() if nlp_keywords else query
        log.debug("[Knowledge] Query diperkaya: %r", enriched_query[:200])

        # ══════════════════════════════════════════════════════════════════════
        # TAHAP 1 — ChromaDB Wide Retrieval
        # ══════════════════════════════════════════════════════════════════════
        k = CONFIG["chroma_retrieval_k"]
        log.info("[Tahap 1] ChromaDB retrieval (k=%d)...", k)
        t1 = time.perf_counter()

        query_emb  = self.models.get_embedding(enriched_query)  # pakai query diperkaya
        candidates = self.chroma.retrieve(query_emb, k=k)

        log.info(
            "[Tahap 1] %d kandidat ditemukan  (%.3fs)",
            len(candidates), time.perf_counter() - t1,
        )

        if not candidates:
            log.warning("[Tahap 1] Tidak ada kandidat — pipeline berhenti.")
            return RAGResponse(
                answer="Maaf, tidak menemukan informasi relevan di database.",
                sources=[],
                final_chunks=[],
                processing_time=time.perf_counter() - t_start,
                intent="knowledge",
            )

        # ══════════════════════════════════════════════════════════════════════
        # TAHAP 2 — Neo4j Context Enrichment
        # ══════════════════════════════════════════════════════════════════════
        log.info(
            "[Tahap 2] Neo4j enrichment (%d kandidat, window=±%d)...",
            len(candidates), CONFIG["context_window"],
        )
        t2 = time.perf_counter()

        enriched = self.neo4j.enrich(candidates, CONFIG["context_window"])

        log.info(
            "[Tahap 2] %d chunk diperkaya  (%.3fs)",
            len(enriched), time.perf_counter() - t2,
        )

        if not enriched:
            log.warning("[Tahap 2] Enrichment kosong — pipeline berhenti.")
            return RAGResponse(
                answer="Maaf, gagal mengambil konteks dari graph database.",
                sources=[],
                final_chunks=[],
                processing_time=time.perf_counter() - t_start,
                intent="knowledge",
            )

        # ══════════════════════════════════════════════════════════════════════
        # TAHAP 3 — Reranking (BGE Cross-Encoder di GPU)
        # Input: context_text = prev + target + next
        # Tujuan: nilai kecocokan teks sekitar chunk vs query
        # ══════════════════════════════════════════════════════════════════════
        reranked_k = CONFIG["reranked_k"]
        log.info(
            "[Tahap 3] BGE reranking (%d → top %d) @ GPU...",
            len(enriched), reranked_k,
        )
        t3 = time.perf_counter()

        scores = self.models.rerank(query, [c.context_text for c in enriched])  # query asli untuk reranking

        for i, score in enumerate(scores):
            if i < len(enriched):
                enriched[i].rerank_score = float(score)

        enriched.sort(key=lambda x: x.rerank_score, reverse=True)
        top_chunks = enriched[:reranked_k]

        log.info(
            "[Tahap 3] Top %d dipilih  (%.3fs)  skor: min=%.4f  max=%.4f",
            len(top_chunks), time.perf_counter() - t3,
            min(c.rerank_score for c in top_chunks),
            max(c.rerank_score for c in top_chunks),
        )

        # ══════════════════════════════════════════════════════════════════════
        # TAHAP 4 — Filtering & Diversifikasi Sumber
        #
        # Strategi dua lapis:
        #   a) max_chunks_per_jurnal — cegah satu jurnal mendominasi konteks
        #   b) final_context_k       — batasi total chunk ke LLM agar prompt
        #                              tidak melebihi VRAM
        # ══════════════════════════════════════════════════════════════════════
        max_per_j = CONFIG["max_chunks_per_jurnal"]
        final_k   = CONFIG["final_context_k"]
        log.info(
            "[Tahap 4] Filtering: max %d/jurnal → ambil top %d...",
            max_per_j, final_k,
        )

        jurnal_count: Dict[str, int] = {}
        final_chunks: List[EnrichedChunk] = []

        for chunk in top_chunks:
            jid = chunk.jurnal_id
            if jurnal_count.get(jid, 0) < max_per_j:
                final_chunks.append(chunk)
                jurnal_count[jid] = jurnal_count.get(jid, 0) + 1
            if len(final_chunks) >= final_k:
                break

        log.info(
            "[Tahap 4] Final: %d chunk dari %d jurnal",
            len(final_chunks), len(jurnal_count),
        )

        # ══════════════════════════════════════════════════════════════════════
        # TAHAP 5 — LLM Generation (Groq API, streaming)
        # ══════════════════════════════════════════════════════════════════════
        messages   = self._build_messages(query, final_chunks, lang=lang)
        answer_gen = self._generate_stream(
            messages,
            stop_event=stop_event,
            temperature=CONFIG["temperature"],
            top_p=CONFIG["top_p"],
            max_new_tokens=CONFIG["max_new_tokens"],
        )

        # ── Sumber referensi untuk UI ─────────────────────────────────────────
        sources = [
            {
                "sub_judul":    c.sub_judul,
                "jurnal":       c.judul_jurnal,
                "penulis":      c.penulis,
                "tahun":        c.tanggal_rilis,
                "doi":          c.doi or "-",
                "halaman":      c.halaman,
                "rerank_score": f"{c.rerank_score:.4f}",
                "vector_score": f"{c.vector_score:.4f}",
            }
            for c in final_chunks
        ]

        elapsed = time.perf_counter() - t_start
        log.info(
            "[Knowledge] Pipeline selesai — %.3fs  |  chunks=%d  sumber=%d",
            elapsed, len(final_chunks), len(sources),
        )
        log.info("═" * 60)

        return RAGResponse(
            answer=answer_gen,
            sources=sources,
            final_chunks=final_chunks,
            processing_time=elapsed,
            intent="knowledge",
        )

    # ── Internal helpers ──────────────────────────────────────────────────────

    @staticmethod
    def _detect_query_intent(text: str) -> str:
        """
        Routing intent: 'knowledge' → RAG pipeline, 'social' → social pipeline.

        Prioritas pengecekan:
          1. Kata/frasa sosial ringan          → 'social'
          2. Tanda tanya (?)                   → 'knowledge'
          3. Kata tanya / perintah informatif  → 'knowledge'
          4. Default                           → 'social'
        """
        normalized = text.lower().strip()
        words      = set(normalized.split())

        # ── 1. Social keywords (prioritas tertinggi) ──────────────────────────
        SOCIAL_PHRASES = {
            "apa kabar", "apakabar", "terima kasih", "terimakasih",
            "sampai jumpa", "selamat tinggal", "thank you",
        }
        SOCIAL_WORDS = {
            "hai", "halo", "hello", "hi", "hey",
            "kabar", "makasih", "thanks",
            "maaf", "sorry", "permisi",
            "dadah", "bye",
            "oke", "ok", "baik", "siap", "sip",
        }
        for phrase in SOCIAL_PHRASES:
            if phrase in normalized:
                log.debug("[Intent] social — frasa: %r", phrase)
                return "social"
        if words & SOCIAL_WORDS:
            log.debug("[Intent] social — kata sosial terdeteksi")
            return "social"

        # ── 2. Tanda tanya eksplisit ──────────────────────────────────────────
        if "?" in text:
            log.debug("[Intent] knowledge — tanda tanya")
            return "knowledge"

        # ── 3. Kata tanya / perintah informatif ──────────────────────────────
        KNOWLEDGE_PHRASES = {
            # frasa Indonesia umum
            "apa itu", "yang mana", "di mana",
            # perintah dengan awalan "coba"
            "coba ranking", "coba urutkan", "coba sebutkan", "coba jelaskan",
            "coba bandingkan", "coba ceritakan", "coba buat", "coba berikan",
            "coba tampilkan", "coba tunjukkan",
            # perintah dengan awalan "tolong"
            "tolong jelaskan", "tolong sebutkan", "tolong ranking",
            "tolong urutkan", "tolong buat", "tolong berikan", "tolong ceritakan",
            # perintah dengan awalan "bisa"
            "bisa jelaskan", "bisa sebutkan", "bisa ranking", "bisa urutkan",
            # frasa urutan/perbandingan
            "dari yang", "mulai dari", "urutan dari",
            "dari terbanyak", "dari terbesar", "dari tertinggi",
            "sampai yang sedikit", "sampai yang kecil", "sampai yang rendah",
        }
        KNOWLEDGE_WORDS = {
            # kata tanya Indonesia
            "apa", "apakah", "bagaimana", "mengapa", "kenapa",
            "siapa", "kapan", "dimana", "berapa", "seberapa", "manakah",
            # perintah informatif langsung
            "jelaskan", "sebutkan", "ceritakan", "gambarkan",
            "deskripsikan", "definisikan", "definisi", "contoh", "contohkan",
            "bandingkan", "bedakan", "perbedaan", "persamaan",
            "cara", "langkah", "proses", "prosedur", "metode",
            "penyebab", "akibat", "dampak", "gejala", "tanda",
            "pengertian", "maksud", "artinya", "fungsi", "manfaat",
            "ciri", "karakteristik", "jenis", "macam", "klasifikasi",
            "penanganan", "pengobatan", "pengendalian", "pencegahan",
            # perintah ranking/urutan — sering tanpa tanda tanya
            "ranking", "rangking", "urutan", "urutkan",
            "peringkat", "daftar", "susun", "susunkan",
            "terbanyak", "tersedikit", "terbesar", "terkecil",
            "tertinggi", "terendah", "terluas",
            # awalan perintah umum
            "buatkan", "berikan", "tampilkan", "tunjukkan",
            "rekomendasikan", "rekomendasi",
            # domain pertanian/hama/penyakit — query domain = knowledge
            "hama", "penyakit", "patogen", "serangan", "infeksi",
            "tanaman", "tumbuhan", "pertanian", "agronomi", "pestisida",
            "pupuk", "lahan", "sawah", "kebun", "panen", "benih", "bibit",
            # kata tanya Inggris
            "what", "how", "why", "when", "where", "who", "which",
            "explain", "describe", "list", "define", "compare", "rank",
            "causes", "symptoms", "treatment", "control", "prevention",
            "give", "show", "recommend", "provide",
        }
        for phrase in KNOWLEDGE_PHRASES:
            if phrase in normalized:
                log.debug("[Intent] knowledge — frasa: %r", phrase)
                return "knowledge"
        if words & KNOWLEDGE_WORDS:
            log.debug("[Intent] knowledge — kata tanya terdeteksi")
            return "knowledge"

        log.debug("[Intent] social — tidak ada indikator knowledge")
        return "social"

    @staticmethod
    def _detect_language(text: str) -> str:
        """
        Deteksi bahasa query.
        Default Indonesia — return 'en' hanya jika ada ≥2 marker Inggris.
        """
        en_markers = {
            "what", "how", "why", "when", "where", "who", "which",
            "explain", "describe", "tell", "list", "give", "show",
            "define", "compare", "is", "are", "does", "do", "can",
            "could", "the", "of", "in", "and", "or", "with", "for",
            "about", "symptoms", "disease", "plant", "fungus",
            "bacteria", "treatment", "control",
        }
        words    = set(text.lower().split())
        en_score = len(words & en_markers)
        return "en" if en_score >= 2 else "id"

    def _build_messages(self, query: str, chunks: List[EnrichedChunk], lang: str = None) -> List[Dict]:
        """
        Bangun messages list format OpenAI/Groq Chat Completions.

        Berbeda dengan versi Mistral lokal yang menghasilkan string prompt,
        Groq API menerima list [{"role": ..., "content": ...}] langsung —
        tidak perlu apply_chat_template manual.

        Konteks menggunakan context_text (prev+target+next) agar LLM
        mendapat gambaran lebih utuh per sub-topik.

        Parameter lang (opsional): 'id' atau 'en'. Jika None, dideteksi otomatis.
        """
        max_chars     = CONFIG["context_max_chars"]
        context_parts: List[str] = []
        used_chars    = 0

        for i, c in enumerate(chunks, 1):
            part = f"[{i}] {c.sub_judul}\n{c.context_text}"
            if used_chars + len(part) > max_chars:
                remaining = max_chars - used_chars
                if remaining > 200:
                    context_parts.append(part[:remaining] + "…")
                break
            context_parts.append(part)
            used_chars += len(part)

        context_str = "\n\n".join(context_parts)

        source_lines = [
            f"[{i}] {c.judul_jurnal} — {c.penulis} ({c.tanggal_rilis})"
            + (f"  DOI: {c.doi}" if c.doi else "")
            + f"  hal. {c.halaman}"
            for i, c in enumerate(chunks, 1)
        ]
        source_str = "\n".join(source_lines)

        lang = lang if lang is not None else self._detect_language(query)
        log.debug("[Prompt] lang=%s  ctx=%d char", lang, used_chars)

        if lang == "id":
            lang_rule      = (
                "WAJIB: Jawab dalam Bahasa Indonesia. "
                "Konteks mungkin berbahasa Inggris — terjemahkan istilah teknis jika perlu."
            )
            question_label = "Pertanyaan"
        else:
            lang_rule      = "Answer entirely in English."
            question_label = "Question"

        system_content = (
            "Anda adalah asisten ahli penyakit tanaman. "
            f"{lang_rule} "
            "Jawab HANYA berdasarkan konteks jurnal berikut. "
            "Jika informasi tidak tersedia, nyatakan tidak tahu. "
            "JANGAN mengarang data.\n\n"
            f"KONTEKS:\n{context_str}\n\n"
            f"SUMBER:\n{source_str}"
        )

        return [
            {"role": "system", "content": system_content},
            {"role": "user",   "content": f"{question_label}: {query}"},
        ]

    def _generate_stream(
        self,
        messages:       List[Dict],
        stop_event:     threading.Event = None,
        temperature:    float = None,
        top_p:          float = None,
        max_new_tokens: int   = None,
    ) -> Generator[str, None, None]:
        """
        Generate jawaban via Groq API dengan streaming SSE.

        Parameter messages adalah list OpenAI-style chat messages:
          [{"role": "system"|"user"|"assistant", "content": "..."}]

        stop_event.set() dari luar → hentikan iterasi streaming lebih awal.
        temperature, top_p, max_new_tokens — jika None, pakai CONFIG default.
        """
        _temperature    = temperature    if temperature    is not None else CONFIG["temperature"]
        _top_p          = top_p          if top_p          is not None else CONFIG["top_p"]
        _max_new_tokens = max_new_tokens if max_new_tokens is not None else CONFIG["max_new_tokens"]

        log.info(
            "[Groq] Generate — model=%s  max_tokens=%d  temperature=%.2f  top_p=%.2f",
            CONFIG["groq_model"], _max_new_tokens, _temperature, _top_p,
        )
        gen_start   = time.perf_counter()
        token_count = 0

        try:
            stream = self.models.groq_client.chat.completions.create(
                model=CONFIG["groq_model"],
                messages=messages,
                max_tokens=_max_new_tokens,
                temperature=_temperature,
                top_p=_top_p,
                stream=True,
            )

            for chunk in stream:
                # Cek stop_event setiap chunk
                if stop_event is not None and stop_event.is_set():
                    log.info("[Groq] Stop event pada token %d", token_count)
                    break

                delta = chunk.choices[0].delta
                text  = getattr(delta, "content", None)
                if text:
                    token_count += 1
                    yield text

        except GeneratorExit:
            log.info("[Groq] GeneratorExit pada token %d", token_count)
        except Exception:
            log.exception("[Groq] Error saat streaming")
            raise
        finally:
            elapsed = time.perf_counter() - gen_start
            log.info(
                "[Groq] ✓ Selesai — %d chunk  %.3fs",
                token_count, elapsed,
            )

    # ── Utility ───────────────────────────────────────────────────────────────

    def simple_retrieval(self, query: str, k: int = 5) -> List[Dict]:
        """Testing retrieval tanpa LLM — kembalikan top-k chunk dengan metadata."""
        log.info("simple_retrieval: query=%r  k=%d", query[:80], k)

        emb        = self.models.get_embedding(query)
        candidates = self.chroma.retrieve(emb, k=k)
        enriched   = self.neo4j.enrich(candidates)

        return [
            {
                "sub_judul":    c.sub_judul,
                "konten_chunk": c.konten_chunk[:500] + ("…" if len(c.konten_chunk) > 500 else ""),
                "jurnal":       c.judul_jurnal,
                "penulis":      c.penulis,
                "tahun":        c.tanggal_rilis,
                "halaman":      c.halaman,
                "vector_score": c.vector_score,
            }
            for c in enriched
        ]


############################################################
# SINGLETON
############################################################

_rag_pipeline: Optional[RAGPipeline] = None


def get_rag_pipeline() -> RAGPipeline:
    """Get-or-create singleton RAGPipeline."""
    global _rag_pipeline
    if _rag_pipeline is None:
        log.info("Membuat RAGPipeline baru...")
        _rag_pipeline = RAGPipeline()
    return _rag_pipeline


def reset_pipeline() -> None:
    """
    Paksa destroy dan rebuild seluruh pipeline + model.
    Dipanggil dari app.py ketika terdeteksi instance lama (stale singleton).
    """
    global _rag_pipeline
    log.warning("reset_pipeline() dipanggil — rebuild dari nol.")
    if _rag_pipeline is not None:
        try:
            _rag_pipeline.close()
        except Exception:
            pass
        _rag_pipeline = None
    RAGModels.reset()
    _rag_pipeline = RAGPipeline()