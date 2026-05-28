#!/usr/bin/env python3
"""Embed a query string and write the vector as JSON to stdout.

Reads the query text from stdin (or the first positional argument),
generates a 384-dim embedding with all-MiniLM-L6-v2, and prints the
vector as a JSON array on a single line.

Usage (from Elixir via System.cmd/3):
    echo "some query text" | python3 analytics/embed_query.py

Exit codes:
    0  — success; vector printed to stdout
    1  — error; message printed to stderr
"""

import json
import sys
from pathlib import Path

MODEL_NAME = "all-MiniLM-L6-v2"

# ---------------------------------------------------------------------------
# Lazy-load the model so import errors surface cleanly
# ---------------------------------------------------------------------------

def get_model():
    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print("ERROR: sentence-transformers not installed. Run: pip install sentence-transformers", file=sys.stderr)
        sys.exit(1)
    return SentenceTransformer(MODEL_NAME)


def main():
    # Accept query from argv or stdin
    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
    else:
        query = sys.stdin.read()

    query = query.strip()
    if not query:
        print("ERROR: empty query", file=sys.stderr)
        sys.exit(1)

    model = get_model()
    # normalize_embeddings=True keeps cosine similarity well-behaved
    vec = model.encode([query], normalize_embeddings=True)[0].tolist()

    # Single line of JSON — easy to parse in Elixir with Jason.decode!
    print(json.dumps(vec))


if __name__ == "__main__":
    main()
