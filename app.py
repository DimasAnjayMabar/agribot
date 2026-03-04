# app.py
import threading
import streamlit as st
import pandas as pd
import plotly.express as px
from typing import Generator

from pipeline import get_rag_pipeline, RAGResponse, EnrichedChunk

# ─────────────────────────────────────────────────────────────────────────────
# PAGE CONFIG
# ─────────────────────────────────────────────────────────────────────────────
st.set_page_config(
    page_title="Agribot",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ─────────────────────────────────────────────────────────────────────────────
# SESSION STATE
# ─────────────────────────────────────────────────────────────────────────────
_DEFAULTS = {
    "messages":    [],
    "last_response": None,
    "stop_event":  None,
    "generating":  False,
    "theme":       "Dark",
}
for k, v in _DEFAULTS.items():
    if k not in st.session_state:
        st.session_state[k] = v

# ─────────────────────────────────────────────────────────────────────────────
# THEMES
# ─────────────────────────────────────────────────────────────────────────────
THEMES = {
    "Light": {
        "bg":              "#f8f9fa",
        "sidebar_bg":      "#ffffff",
        "card_bg":         "#ffffff",
        "card_border":     "#e0e0e0",
        "text":            "#1a1a1a",
        "text_muted":      "#555555",
        "user_msg_bg":     "#e3f2fd",
        "user_msg_border": "#2196f3",
        "user_msg_text":   "#0d47a1",
        "bot_msg_bg":      "#e8f5e9",
        "bot_msg_border":  "#4caf50",
        "bot_msg_text":    "#1b5e20",
        "header_grad":     "linear-gradient(135deg, #43a047 0%, #1b5e20 100%)",
        "metric_bg":       "#f1f8e9",
        "step_bg":         "#ffffff",
        "step_border":     "#e0e0e0",
        "expander_bg":     "#f9fbe7",
        "plotly_template": "plotly_white",
        "info_bg":         "#e3f2fd",
        "info_text":       "#0d47a1",
        "badge_vector":    "#1565c0",
        "badge_rerank":    "#2e7d32",
    },
    "Dark": {
        "bg":              "#121212",
        "sidebar_bg":      "#1e1e1e",
        "card_bg":         "#1e1e1e",
        "card_border":     "#333333",
        "text":            "#e0e0e0",
        "text_muted":      "#9e9e9e",
        "user_msg_bg":     "#1a2a3a",
        "user_msg_border": "#42a5f5",
        "user_msg_text":   "#90caf9",
        "bot_msg_bg":      "#1a2a1a",
        "bot_msg_border":  "#66bb6a",
        "bot_msg_text":    "#a5d6a7",
        "header_grad":     "linear-gradient(135deg, #2e7d32 0%, #1b5e20 100%)",
        "metric_bg":       "#1e2e1e",
        "step_bg":         "#1e1e1e",
        "step_border":     "#333333",
        "expander_bg":     "#1a2a1a",
        "plotly_template": "plotly_dark",
        "info_bg":         "#1a2a3a",
        "info_text":       "#90caf9",
        "badge_vector":    "#42a5f5",
        "badge_rerank":    "#66bb6a",
    },
}

def T() -> dict:
    choice = st.session_state.theme
    return THEMES.get(choice, THEMES["Dark"])

# ─────────────────────────────────────────────────────────────────────────────
# CSS
# ─────────────────────────────────────────────────────────────────────────────
def inject_css():
    t = T()
    st.markdown(f"""
<style>
    .stApp {{
        background-color: {t['bg']};
        color: {t['text']};
    }}
    [data-testid="stSidebar"] {{
        background-color: {t['sidebar_bg']};
    }}
    [data-testid="stSidebar"] * {{
        color: {t['text']} !important;
    }}
    .stApp p, .stApp span, .stApp li, .stApp div {{
        color: {t['text']};
    }}

    /* Header */
    .main-header {{
        background: {t['header_grad']};
        padding: 2rem;
        border-radius: 12px;
        color: #ffffff;
        margin-bottom: 2rem;
        box-shadow: 0 4px 16px rgba(0,0,0,0.18);
    }}
    .main-header h1, .main-header p {{ color: #ffffff !important; }}

    /* Chat bubbles */
    [data-testid="stChatMessage"] {{
        background-color: {t['card_bg']};
        border: 1px solid {t['card_border']};
        border-radius: 10px;
        padding: 0.5rem;
    }}
    [data-testid="stChatMessage"] p,
    [data-testid="stChatMessage"] span,
    [data-testid="stChatMessage"] li,
    [data-testid="stChatMessage"] div {{
        color: {t['text']} !important;
    }}

    /* Source cards */
    .source-card {{
        background: {t['card_bg']};
        padding: 1rem 1.2rem;
        border-radius: 8px;
        border: 1px solid {t['card_border']};
        margin-bottom: 0.6rem;
        transition: transform 0.2s, box-shadow 0.2s;
    }}
    .source-card:hover {{
        transform: translateY(-2px);
        box-shadow: 0 4px 12px rgba(0,0,0,0.18);
    }}
    .source-card h4, .source-card p, .source-card strong {{
        color: {t['text']} !important;
        margin: 0.15rem 0;
    }}
    .score-badge {{
        display: inline-block;
        border-radius: 4px;
        padding: 1px 7px;
        font-size: 0.75rem;
        font-weight: 600;
        margin-right: 4px;
    }}
    .badge-vector {{ background: {t['badge_vector']}; color: #fff; }}
    .badge-rerank {{ background: {t['badge_rerank']}; color: #fff; }}

    /* Pipeline steps */
    .pipeline-step {{
        display: flex;
        align-items: center;
        margin-bottom: 0.8rem;
        padding: 0.75rem;
        background: {t['step_bg']};
        border-radius: 8px;
        border: 1px solid {t['step_border']};
        color: {t['text']};
    }}
    .pipeline-step strong, .pipeline-step small {{
        color: {t['text']} !important;
    }}
    .step-number {{
        background: #4caf50;
        color: white;
        min-width: 30px;
        height: 30px;
        border-radius: 50%;
        display: flex;
        align-items: center;
        justify-content: center;
        margin-right: 1rem;
        font-weight: bold;
        flex-shrink: 0;
    }}

    /* Metrics */
    [data-testid="stMetric"] {{
        background-color: {t['metric_bg']};
        border-radius: 8px;
        padding: 0.5rem;
    }}
    [data-testid="stMetric"] * {{
        color: {t['text']} !important;
    }}

    /* Expander */
    [data-testid="stExpander"] {{
        background-color: {t['expander_bg']};
        border: 1px solid {t['card_border']};
        border-radius: 8px;
    }}
    [data-testid="stExpander"] * {{
        color: {t['text']} !important;
    }}

    /* Info box */
    [data-testid="stInfo"] {{
        background-color: {t['info_bg']} !important;
        border-radius: 6px;
    }}
    [data-testid="stInfo"] * {{
        color: {t['info_text']} !important;
    }}

    /* Dataframe */
    [data-testid="stDataFrame"] {{
        background-color: {t['card_bg']};
    }}

    /* Tabs */
    [data-testid="stTabs"] button {{
        color: {t['text']} !important;
    }}

    /* Stop button */
    .stop-btn button {{
        background: linear-gradient(135deg, #e53935, #b71c1c) !important;
        color: white !important;
        border: none !important;
        border-radius: 8px !important;
        font-weight: 600 !important;
        width: 100% !important;
        padding: 0.5rem 1rem !important;
    }}

    /* Footer */
    .footer-text {{
        text-align: center;
        color: {t['text_muted']};
    }}

    @keyframes fadeIn {{
        from {{ opacity: 0; transform: translateY(10px); }}
        to   {{ opacity: 1; transform: translateY(0); }}
    }}
</style>
""", unsafe_allow_html=True)

inject_css()

# ─────────────────────────────────────────────────────────────────────────────
# HEADER
# ─────────────────────────────────────────────────────────────────────────────
st.markdown("""
<div class="main-header">
    <h1>🌱 Agribot</h1>
    <p style="margin:0; opacity:0.85;">Chatbot Penyakit Tanaman — RAG Pipeline 5-Tahap</p>
</div>
""", unsafe_allow_html=True)

# ─────────────────────────────────────────────────────────────────────────────
# SIDEBAR
# ─────────────────────────────────────────────────────────────────────────────
with st.sidebar:
    st.header("⚙️ Konfigurasi Pipeline")

    # Theme
    st.subheader("🎨 Tampilan")
    theme_choice = st.radio(
        "Mode Tampilan",
        options=["Light", "Dark"],
        index=["Light", "Dark"].index(st.session_state.theme),
        horizontal=True,
    )
    if theme_choice != st.session_state.theme:
        st.session_state.theme = theme_choice
        st.rerun()

    st.markdown("---")

    # ── Tahap 1: ChromaDB ────────────────────────────────────────────────────
    st.subheader("Tahap 1 — ChromaDB Retrieval")
    chroma_k = st.slider(
        "Kandidat awal (k)",
        min_value=5, max_value=30, value=30,
        help="Jumlah chunk yang diambil dari vector search ChromaDB",
    )

    # ── Tahap 2: Neo4j ───────────────────────────────────────────────────────
    st.subheader("Tahap 2 — Neo4j Context Window")
    context_window = st.slider(
        "Window PREV/NEXT (±)",
        min_value=0, max_value=3, value=3,
        help="Berapa chunk sebelum dan sesudah yang digabung sebagai konteks",
    )

    # ── Tahap 3: Reranking ───────────────────────────────────────────────────
    st.subheader("Tahap 3 — Reranking")
    rerank_k = st.slider(
        "Top-N setelah reranking",
        min_value=3, max_value=10, value=10,
        help="Chunk terbaik yang lolos ke tahap filtering",
    )

    # ── Tahap 4: Filtering ───────────────────────────────────────────────────
    st.subheader("Tahap 4 — Filtering")
    max_per_jurnal = st.slider(
        "Maks chunk per jurnal",
        min_value=1, max_value=5, value=5,
        help="Diversifikasi sumber — cegah satu jurnal mendominasi",
    )
    final_k = st.slider(
        "Chunk final ke LLM",
        min_value=1, max_value=5, value=5,
        help="Total chunk yang masuk ke prompt LLM",
    )

    # ── LLM ─────────────────────────────────────────────────────────────────
    st.subheader("🤖 LLM Settings")
    temperature = st.slider(
        "Temperature",
        min_value=0.0, max_value=1.0, value=0.2, step=0.05,
        help="0 = deterministik, 1 = kreatif",
    )
    show_details = st.checkbox("Tampilkan detail pipeline", value=True)

    st.markdown("---")

    # ── Status Sistem ────────────────────────────────────────────────────────
    st.subheader("🖥️ Status Sistem")
    try:
        pipeline = get_rag_pipeline()
        st.success("✅ Pipeline siap")
        with st.expander("Model Info"):
            import torch
            st.write(f"**Embedding:** `{type(pipeline.models.embedding_model).__name__}` @ CPU")
            st.write(f"**Reranker:** `{type(pipeline.models.reranker).__name__}` @ CPU")
            from pipeline import CONFIG as _CFG
            st.write(f"**LLM:** Groq API — `{_CFG['groq_model']}`")
            if torch.cuda.is_available():
                vram_used  = torch.cuda.memory_allocated() / 1e9
                vram_total = torch.cuda.get_device_properties(0).total_memory / 1e9
                st.write(f"**VRAM:** {vram_used:.1f} / {vram_total:.1f} GB")
            st.write(f"**ChromaDB:** `{pipeline.chroma.collection.name}`"
                     f" ({pipeline.chroma.collection.count()} dok)")
    except Exception as e:
        st.error(f"❌ Error: {e}")

    st.markdown("---")
    st.markdown("### 📊 Alur Pipeline")
    st.markdown("""
    1. **ChromaDB** — Vector search `konten_isi`
    2. **Neo4j** — PREV + target + NEXT context
    3. **BGE Reranker** — Cross-encoder scoring @ GPU
    4. **Filter** — Top-N + diversifikasi sumber
    5. **Groq API** — Streaming answer via Groq
    """)

# ─────────────────────────────────────────────────────────────────────────────
# HELPER — sinkronisasi config sidebar → backend CONFIG
# ─────────────────────────────────────────────────────────────────────────────
def _sync_config():
    """Dorong nilai sidebar ke CONFIG backend sebelum query dijalankan."""
    from pipeline import CONFIG
    CONFIG["chroma_retrieval_k"]    = chroma_k
    CONFIG["context_window"]        = context_window
    CONFIG["reranked_k"]            = rerank_k
    CONFIG["max_chunks_per_jurnal"] = max_per_jurnal
    CONFIG["final_context_k"]       = final_k
    CONFIG["temperature"]           = temperature

# ─────────────────────────────────────────────────────────────────────────────
# HELPER — source card HTML
# ─────────────────────────────────────────────────────────────────────────────
def _source_card(i: int, src: dict) -> str:
    doi_html = (
        f'<a href="https://doi.org/{src["doi"]}" target="_blank">{src["doi"]}</a>'
        if src.get("doi") and src["doi"] != "-"
        else src.get("doi", "-")
    )
    return f"""
<div class="source-card">
    <h4>📄 [{i}] {src['sub_judul']}</h4>
    <p><strong>Jurnal:</strong> {src['jurnal']}</p>
    <p><strong>Penulis:</strong> {src['penulis']} &nbsp;|&nbsp;
       <strong>Tahun:</strong> {src['tahun']} &nbsp;|&nbsp;
       <strong>Hal.</strong> {src['halaman']}</p>
    <p><strong>DOI:</strong> {doi_html}</p>
    <p>
        <span class="score-badge badge-vector">vector {src['vector_score']}</span>
        <span class="score-badge badge-rerank">rerank {src['rerank_score']}</span>
    </p>
</div>
"""

# ─────────────────────────────────────────────────────────────────────────────
# STREAM HELPER
# ─────────────────────────────────────────────────────────────────────────────
def stream_response(query: str) -> Generator:
    """
    Menjalankan pipeline dan men-stream token jawaban.
    Menyimpan RAGResponse lengkap ke session_state.last_response
    setelah stream selesai.
    """
    _sync_config()

    pipeline   = get_rag_pipeline()
    stop_event = threading.Event()

    st.session_state.stop_event = stop_event
    st.session_state.generating = True

    try:
        response: RAGResponse = pipeline.process_query(query, stop_event=stop_event)

        full_answer = ""
        for token in response.answer:
            full_answer += token
            yield token

        # Ganti generator dengan string final agar bisa disimpan di session_state
        response.answer = full_answer
        st.session_state.last_response = response

    except Exception as e:
        yield f"\n\n⚠️ Error: {e}"
    finally:
        st.session_state.generating = False
        st.session_state.stop_event = None

# ─────────────────────────────────────────────────────────────────────────────
# CHAT HISTORY
# ─────────────────────────────────────────────────────────────────────────────
for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])

        if message["role"] == "assistant" and message.get("sources"):
            with st.expander(f"📚 Sumber Referensi ({len(message['sources'])})"):
                for i, src in enumerate(message["sources"], 1):
                    st.markdown(_source_card(i, src), unsafe_allow_html=True)

# ─────────────────────────────────────────────────────────────────────────────
# CHAT INPUT
# ─────────────────────────────────────────────────────────────────────────────
if prompt := st.chat_input("Tanyakan tentang penyakit tanaman..."):
    st.session_state.messages.append({"role": "user", "content": prompt})

    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        msg_placeholder  = st.empty()
        stop_placeholder = st.empty()
        full_response    = ""

        # Tombol stop — hanya aktif saat generasi
        with stop_placeholder.container():
            st.markdown('<div class="stop-btn">', unsafe_allow_html=True)
            if st.button("⏹ Stop Generate", key="stop_btn_active"):
                if st.session_state.stop_event:
                    st.session_state.stop_event.set()
            st.markdown("</div>", unsafe_allow_html=True)

        # Info tahapan pipeline (opsional)
        with st.spinner("Memproses pipeline..."):
            if show_details:
                cols = st.columns(5)
                labels = [
                    ("🔍", f"ChromaDB k={chroma_k}"),
                    ("🕸️", f"Neo4j ±{context_window}"),
                    ("🎯", f"Reranking top {rerank_k}"),
                    ("🗂️", f"Filter top {final_k}"),
                    ("🤖", "LLM (GPU)"),
                ]
                for col, (icon, label) in zip(cols, labels):
                    with col:
                        st.info(f"{icon} {label}")

            for token in stream_response(prompt):
                full_response += token
                msg_placeholder.markdown(full_response + "▌")

        stop_placeholder.empty()
        msg_placeholder.markdown(full_response)

        # Sumber referensi langsung di bawah jawaban
        response = st.session_state.last_response
        if response and response.sources:
            with st.expander(f"📚 Sumber Referensi ({len(response.sources)})"):
                # Tabel ringkasan
                df_src = pd.DataFrame(response.sources)
                st.dataframe(
                    df_src[[
                        "sub_judul", "jurnal", "penulis",
                        "tahun", "halaman", "rerank_score", "vector_score",
                    ]].rename(columns={
                        "sub_judul":    "Sub-Judul",
                        "jurnal":       "Jurnal",
                        "penulis":      "Penulis",
                        "tahun":        "Tahun",
                        "halaman":      "Hal.",
                        "rerank_score": "Rerank ↑",
                        "vector_score": "Vector ↓",
                    }),
                    use_container_width=True,
                )

                # Cards detail
                for i, src in enumerate(response.sources, 1):
                    st.markdown(_source_card(i, src), unsafe_allow_html=True)

    # Simpan ke history
    if st.session_state.last_response:
        st.session_state.messages.append({
            "role":    "assistant",
            "content": full_response,
            "sources": st.session_state.last_response.sources,
        })

# ─────────────────────────────────────────────────────────────────────────────
# TABS ANALISIS (muncul setelah ada respons)
# ─────────────────────────────────────────────────────────────────────────────
if st.session_state.last_response:
    response = st.session_state.last_response
    t = T()

    st.markdown("---")
    tabs = st.tabs(["📊 Analisis Pipeline", "🔍 Chunk Retrieved", "📈 Visualisasi Skor"])

    # ── Tab 0: Analisis Pipeline ─────────────────────────────────────────────
    with tabs[0]:
        st.subheader("📊 Performa Pipeline")

        col1, col2, col3, col4 = st.columns(4)
        with col1:
            st.metric("Waktu Total", f"{response.processing_time:.2f}s")
        with col2:
            st.metric("Chunk Final", len(response.final_chunks))
        with col3:
            st.metric("Sumber Berbeda",
                      len({c.jurnal_id for c in response.final_chunks}))
        with col4:
            avg_rr = (
                sum(c.rerank_score for c in response.final_chunks) / len(response.final_chunks)
                if response.final_chunks else 0.0
            )
            st.metric("Avg Rerank Score", f"{avg_rr:.4f}")

        st.subheader("Tahapan Pipeline")
        steps = [
            ("1", "ChromaDB Retrieval",
             f"Vector search → {chroma_k} kandidat dari collection 'konten_isi'"),
            ("2", "Neo4j Enrichment",
             f"Ambil prev ±{context_window} chunk + metadata Jurnal via graph traversal"),
            ("3", "BGE Reranking @ CPU",
             f"Cross-encoder scoring context_text vs query → top {rerank_k}"),
            ("4", "Filtering",
             f"Maks {max_per_jurnal} chunk/jurnal → {final_k} chunk final ke LLM"),
            ("5", "Groq API (gpt-oss-120b)",
             "Streaming answer via Groq API"),
        ]
        for num, title, desc in steps:
            st.markdown(f"""
            <div class="pipeline-step">
                <div class="step-number">{num}</div>
                <div>
                    <strong>{title}</strong><br>
                    <small>{desc}</small>
                </div>
            </div>
            """, unsafe_allow_html=True)

    # ── Tab 1: Chunk Retrieved ───────────────────────────────────────────────
    with tabs[1]:
        st.subheader("🔍 Chunk Final yang Masuk ke LLM")

        if response.final_chunks:
            chunk_rows = []
            for i, c in enumerate(response.final_chunks, 1):
                chunk_rows.append({
                    "Rank":          i,
                    "Sub-Judul":     c.sub_judul,
                    "Preview":       c.konten_chunk[:180] + "…"
                                     if len(c.konten_chunk) > 180 else c.konten_chunk,
                    "Jurnal":        c.judul_jurnal,
                    "Penulis":       c.penulis,
                    "Tahun":         c.tanggal_rilis,
                    "Hal.":          c.halaman,
                    "Vector ↓":      f"{c.vector_score:.4f}",
                    "Rerank ↑":      f"{c.rerank_score:.4f}",
                })

            df_chunks = pd.DataFrame(chunk_rows)
            st.dataframe(df_chunks, use_container_width=True)

            # Preview context_text tiap chunk
            st.subheader("Context Text per Chunk (prev + target + next)")
            for i, c in enumerate(response.final_chunks, 1):
                with st.expander(f"[{i}] {c.sub_judul} — hal. {c.halaman}"):
                    st.markdown(f"**Jurnal:** {c.judul_jurnal}  |  **Penulis:** {c.penulis}")
                    st.markdown(f"**DOI:** {c.doi or '-'}")
                    st.text_area(
                        "context_text",
                        value=c.context_text,
                        height=180,
                        key=f"ctx_{i}",
                        disabled=True,
                    )

    # ── Tab 2: Visualisasi Skor ──────────────────────────────────────────────
    with tabs[2]:
        st.subheader("📈 Perbandingan Vector vs Rerank Score")

        if response.final_chunks:
            viz_data = [
                {
                    "Rank":          i,
                    "Sub-Judul":     c.sub_judul,
                    "Vector Score":  c.vector_score,
                    "Rerank Score":  c.rerank_score,
                    "Jurnal":        c.judul_jurnal,
                }
                for i, c in enumerate(response.final_chunks, 1)
            ]
            df_viz = pd.DataFrame(viz_data)

            # Bar: rerank score per chunk
            fig_bar = px.bar(
                df_viz,
                x="Rank",
                y="Rerank Score",
                color="Jurnal",
                hover_data=["Sub-Judul", "Vector Score"],
                title="Rerank Score per Chunk Final",
                text_auto=".4f",
                template=t["plotly_template"],
            )
            fig_bar.update_layout(xaxis=dict(tickmode="linear"))
            st.plotly_chart(fig_bar, use_container_width=True)

            # Scatter: vector vs rerank
            fig_scatter = px.scatter(
                df_viz,
                x="Vector Score",
                y="Rerank Score",
                color="Jurnal",
                size=[1.0] * len(df_viz),
                hover_data=["Sub-Judul", "Rank"],
                title="Vector Score (↓ lebih baik) vs Rerank Score (↑ lebih baik)",
                labels={
                    "Vector Score": "Vector Score ↓",
                    "Rerank Score": "Rerank Score ↑",
                },
                template=t["plotly_template"],
            )
            st.plotly_chart(fig_scatter, use_container_width=True)

            # Distribusi jurnal
            jurnal_counts = df_viz["Jurnal"].value_counts().reset_index()
            jurnal_counts.columns = ["Jurnal", "Chunk"]
            if len(jurnal_counts) > 1:
                fig_pie = px.pie(
                    jurnal_counts,
                    names="Jurnal",
                    values="Chunk",
                    title="Distribusi Chunk per Jurnal",
                    hole=0.4,
                    template=t["plotly_template"],
                )
                st.plotly_chart(fig_pie, use_container_width=True)

# ─────────────────────────────────────────────────────────────────────────────
# FOOTER
# ─────────────────────────────────────────────────────────────────────────────
st.markdown("---")
st.markdown("""
<div class="footer-text">
    <p><strong>Agribot</strong> | RAG 5-Tahap: ChromaDB → Neo4j → BGE → Filter → Groq API</p>
</div>
""", unsafe_allow_html=True)