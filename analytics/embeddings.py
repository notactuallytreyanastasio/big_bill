#!/usr/bin/env python3
"""Embedding pipeline for Big Beautiful Bill.

Generates 384-dim embeddings using all-MiniLM-L6-v2 for:
  - Bill sections (from DuckDB)
  - Decision graph nodes (from docs/graph-data.json)
  - Analysis file chunks (~500 chars with overlap)

Writes results to Postgres via psycopg2.

Usage:
    python3 analytics/embeddings.py
    python3 analytics/embeddings.py --source sections
    python3 analytics/embeddings.py --source graph_nodes
    python3 analytics/embeddings.py --source analysis
    python3 analytics/embeddings.py --dry-run
"""

import argparse
import json
import sys
from pathlib import Path

import duckdb
import psycopg2
import psycopg2.extras

# Ensure the analytics package is importable when run directly
sys.path.insert(0, str(Path(__file__).parent))

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DB_PATH = Path(__file__).parent / "db" / "big_bill.duckdb"
GRAPH_DATA_PATH = Path(__file__).parent.parent / "docs" / "graph-data.json"
ANALYSIS_DIR = Path(__file__).parent.parent / "analysis"

PG_DSN = "host=localhost port=5432 dbname=big_bill_dev user=postgres password=postgres"

MODEL_NAME = "all-MiniLM-L6-v2"
EMBEDDING_DIM = 384

CHUNK_SIZE = 500       # characters per analysis chunk
CHUNK_OVERLAP = 100    # overlap between consecutive chunks


# ---------------------------------------------------------------------------
# Chunking helpers
# ---------------------------------------------------------------------------

def chunk_text(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    """Split *text* into overlapping chunks of ~*size* characters.

    Splits prefer sentence boundaries ('. ') when available.
    """
    text = text.strip()
    if len(text) <= size:
        return [text] if text else []

    chunks = []
    start = 0
    while start < len(text):
        end = start + size
        if end >= len(text):
            chunk = text[start:]
        else:
            # Try to break at a sentence boundary near the end
            boundary = text.rfind(". ", start, end)
            if boundary != -1 and boundary > start + overlap:
                end = boundary + 1
            chunk = text[start:end]

        chunk = chunk.strip()
        if chunk:
            chunks.append(chunk)

        start = end - overlap

    return chunks


# ---------------------------------------------------------------------------
# Data loaders
# ---------------------------------------------------------------------------

def load_sections() -> list[dict]:
    """Return all bill sections from DuckDB as embedding-ready records."""
    if not DB_PATH.exists():
        print(f"  WARNING: DuckDB not found at {DB_PATH}, skipping sections")
        return []

    con = duckdb.connect(str(DB_PATH), read_only=True)
    rows = con.execute(
        "SELECT section_number, section_title, summary, mechanism FROM sections ORDER BY section_number"
    ).fetchall()
    con.close()

    records = []
    for section_number, section_title, summary, mechanism in rows:
        parts = [p for p in [section_title, summary, mechanism] if p]
        content = "\n".join(parts)
        if content.strip():
            records.append({
                "source_type": "section",
                "source_id": str(section_number),
                "title": section_title or str(section_number),
                "content": content,
                "metadata": {"section_number": section_number},
            })

    print(f"  Loaded {len(records)} sections from DuckDB")
    return records


def load_graph_nodes() -> list[dict]:
    """Return all decision graph nodes as embedding-ready records."""
    if not GRAPH_DATA_PATH.exists():
        print(f"  WARNING: graph-data.json not found at {GRAPH_DATA_PATH}, skipping nodes")
        return []

    with open(GRAPH_DATA_PATH) as f:
        data = json.load(f)

    nodes = data.get("nodes", [])
    records = []
    for node in nodes:
        node_id = str(node.get("id", ""))
        title = node.get("title", "").strip()
        description = node.get("description", "").strip()
        node_type = node.get("node_type", "")

        content_parts = [p for p in [title, description] if p]
        content = "\n".join(content_parts)

        if content.strip():
            records.append({
                "source_type": "graph_node",
                "source_id": node_id,
                "title": title or node_id,
                "content": content,
                "metadata": {"node_type": node_type, "node_id": node_id},
            })

    print(f"  Loaded {len(records)} graph nodes")
    return records


def load_analysis_chunks() -> list[dict]:
    """Chunk all analysis markdown files into ~500-char segments."""
    if not ANALYSIS_DIR.exists():
        print(f"  WARNING: analysis dir not found at {ANALYSIS_DIR}, skipping")
        return []

    md_files = sorted(ANALYSIS_DIR.glob("*.md"))
    if not md_files:
        print(f"  WARNING: no .md files found in {ANALYSIS_DIR}")
        return []

    records = []
    for md_path in md_files:
        text = md_path.read_text(encoding="utf-8", errors="replace")
        chunks = chunk_text(text)
        for i, chunk in enumerate(chunks):
            chunk_id = f"{md_path.stem}::{i}"
            records.append({
                "source_type": "analysis",
                "source_id": chunk_id,
                "title": md_path.stem.replace("_", " ").title(),
                "content": chunk,
                "metadata": {
                    "filename": md_path.name,
                    "chunk_index": i,
                    "total_chunks": len(chunks),
                },
            })

    print(f"  Loaded {len(records)} analysis chunks from {len(md_files)} files")
    return records


# ---------------------------------------------------------------------------
# Embedding generation
# ---------------------------------------------------------------------------

def load_model():
    """Load and return the sentence-transformers model (lazy import)."""
    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print("ERROR: sentence-transformers is not installed.")
        print("Run: pip install sentence-transformers")
        sys.exit(1)

    print(f"  Loading model: {MODEL_NAME}")
    model = SentenceTransformer(MODEL_NAME)
    return model


def embed_records(model, records: list[dict], batch_size: int = 64) -> list[dict]:
    """Add an 'embedding' key to each record in-place and return records."""
    texts = [r["content"] for r in records]
    total = len(texts)
    print(f"  Embedding {total} records in batches of {batch_size}...")

    all_embeddings = []
    for start in range(0, total, batch_size):
        batch = texts[start : start + batch_size]
        vecs = model.encode(batch, show_progress_bar=False, normalize_embeddings=True)
        all_embeddings.extend(vecs.tolist())
        done = min(start + batch_size, total)
        print(f"    {done}/{total}", end="\r", flush=True)

    print()  # newline after progress
    for record, vec in zip(records, all_embeddings):
        record["embedding"] = vec

    return records


# ---------------------------------------------------------------------------
# Postgres upsert
# ---------------------------------------------------------------------------

def upsert_embeddings(records: list[dict], dsn: str = PG_DSN) -> int:
    """Upsert embedding records into Postgres. Returns count inserted/updated."""
    if not records:
        return 0

    conn = psycopg2.connect(dsn)
    try:
        with conn.cursor() as cur:
            upserted = 0
            for rec in records:
                vec_str = "[" + ",".join(f"{v:.8f}" for v in rec["embedding"]) + "]"
                cur.execute(
                    """
                    INSERT INTO search_embeddings
                        (source_type, source_id, title, content, embedding, metadata)
                    VALUES (%s, %s, %s, %s, %s::vector, %s)
                    ON CONFLICT (source_type, source_id) DO UPDATE SET
                        title      = EXCLUDED.title,
                        content    = EXCLUDED.content,
                        embedding  = EXCLUDED.embedding,
                        metadata   = EXCLUDED.metadata,
                        inserted_at = NOW()
                    """,
                    (
                        rec["source_type"],
                        rec["source_id"],
                        rec["title"],
                        rec["content"],
                        vec_str,
                        json.dumps(rec["metadata"]),
                    ),
                )
                upserted += 1

            conn.commit()
        return upserted
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def run_pipeline(sources: list[str] | None = None, dry_run: bool = False):
    """Run the full embedding pipeline for the given sources (or all)."""
    print("=" * 60)
    print("Big Beautiful Bill — Embedding Pipeline")
    print("=" * 60)

    all_sources = sources or ["sections", "graph_nodes", "analysis"]

    # Step 1: Collect records
    print("\n[1/3] Loading source data...")
    records = []
    if "sections" in all_sources:
        records.extend(load_sections())
    if "graph_nodes" in all_sources:
        records.extend(load_graph_nodes())
    if "analysis" in all_sources:
        records.extend(load_analysis_chunks())

    if not records:
        print("No records to embed. Exiting.")
        return

    print(f"  Total records: {len(records)}")

    # Step 2: Generate embeddings
    print("\n[2/3] Generating embeddings...")
    model = load_model()
    records = embed_records(model, records)

    if dry_run:
        print("\n[DRY RUN] Skipping Postgres write.")
        print(f"  Would upsert {len(records)} records.")
        sample = records[0]
        print(f"  Sample: source_type={sample['source_type']!r} source_id={sample['source_id']!r}")
        print(f"  Embedding dim: {len(sample['embedding'])}")
        return

    # Step 3: Write to Postgres
    print("\n[3/3] Writing to Postgres...")
    count = upsert_embeddings(records)
    print(f"  Upserted {count} records.")

    print("\n" + "=" * 60)
    print("Embedding pipeline complete.")
    print("=" * 60)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Generate embeddings for Big Beautiful Bill")
    ap.add_argument(
        "--source",
        choices=["sections", "graph_nodes", "analysis"],
        action="append",
        dest="sources",
        help="Which source to embed (default: all). Repeatable.",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Generate embeddings but do not write to Postgres",
    )
    args = ap.parse_args()

    run_pipeline(sources=args.sources, dry_run=args.dry_run)
