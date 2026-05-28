"""Load the deciduous decision graph into DuckDB for analytical queries.

Reads docs/graph-data.json and creates graph_nodes, graph_edges,
and graph_documents tables that can be joined with the section-level data.
"""

import json
from pathlib import Path


def load_graph_data(graph_path: str) -> dict:
    """Load and parse the graph JSON export."""
    with open(graph_path) as f:
        return json.load(f)


def create_graph_tables(con):
    """Create tables for graph data."""
    con.execute("DROP TABLE IF EXISTS graph_documents CASCADE")
    con.execute("DROP TABLE IF EXISTS graph_edges CASCADE")
    con.execute("DROP TABLE IF EXISTS graph_nodes CASCADE")

    con.execute("""
        CREATE TABLE graph_nodes (
            node_id        INTEGER PRIMARY KEY,
            node_type      VARCHAR,
            status         VARCHAR,
            title          VARCHAR,
            description    VARCHAR,
            confidence     INTEGER,
            branch         VARCHAR,
            section_number VARCHAR,
            created_at     VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE graph_edges (
            edge_id        INTEGER PRIMARY KEY,
            from_node      INTEGER,
            to_node        INTEGER,
            edge_type      VARCHAR,
            reason         VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE graph_documents (
            doc_id         INTEGER PRIMARY KEY,
            node_id        INTEGER,
            filename       VARCHAR,
            description    VARCHAR
        )
    """)


def extract_section_number(title: str) -> str | None:
    """Try to extract a section number from a node title like 'SEC. 71119 — ...'"""
    import re
    m = re.search(r"SEC\.\s*(\d+)", title or "")
    return m.group(1) if m else None


def load_graph_into_db(con, graph_path: str):
    """Load the full graph into DuckDB."""
    data = load_graph_data(graph_path)

    nodes = data.get("nodes", [])
    edges = data.get("edges", [])
    docs = data.get("documents", [])

    create_graph_tables(con)

    # Load nodes
    for node in nodes:
        title = node.get("title", "")
        con.execute(
            """INSERT INTO graph_nodes
               (node_id, node_type, status, title, description,
                confidence, branch, section_number, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                node.get("id"),
                node.get("node_type"),
                node.get("status"),
                title,
                node.get("description", ""),
                node.get("confidence"),
                node.get("branch"),
                extract_section_number(title),
                node.get("created_at"),
            ],
        )

    # Load edges
    for edge in edges:
        con.execute(
            """INSERT INTO graph_edges
               (edge_id, from_node, to_node, edge_type, reason)
               VALUES (?, ?, ?, ?, ?)""",
            [
                edge.get("id"),
                edge.get("from_node_id") or edge.get("from_node") or edge.get("from"),
                edge.get("to_node_id") or edge.get("to_node") or edge.get("to"),
                edge.get("edge_type") or edge.get("type"),
                edge.get("rationale") or edge.get("reason", ""),
            ],
        )

    # Load documents
    for doc in docs:
        con.execute(
            """INSERT INTO graph_documents
               (doc_id, node_id, filename, description)
               VALUES (?, ?, ?, ?)""",
            [
                doc.get("id"),
                doc.get("node_id"),
                doc.get("original_filename", ""),
                doc.get("description", ""),
            ],
        )

    print(f"  Loaded {len(nodes)} graph nodes, {len(edges)} edges, {len(docs)} documents")


def extract_all(graph_path: str) -> dict:
    """Return graph stats without loading (for pipeline reporting)."""
    data = load_graph_data(graph_path)
    return {
        "nodes": len(data.get("nodes", [])),
        "edges": len(data.get("edges", [])),
        "documents": len(data.get("documents", [])),
    }
