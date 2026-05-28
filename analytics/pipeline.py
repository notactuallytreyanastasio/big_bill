#!/usr/bin/env python3
"""Big Beautiful Bill analytics pipeline.

Parses analysis markdown files, extracts structured data,
loads into DuckDB, and generates cross-cutting reports.

Usage:
    python3 analytics/pipeline.py                  # Full pipeline
    python3 analytics/pipeline.py --report spending # Single report
    python3 analytics/pipeline.py --parse-only      # Parse + load, no reports
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

# Ensure analytics package is importable
sys.path.insert(0, str(Path(__file__).parent))

from parser import parse_all
from loader import init_db, get_connection
from extractors.money import extract_all as extract_money
from extractors.entities import extract_all as extract_entities


def load_money(con, money_flows):
    """Load money flows into DuckDB."""
    for i, flow in enumerate(money_flows):
        con.execute(
            """INSERT INTO money_flows
               (id, section_number, title_num, amount_text, amount_dollars,
                amount_unit, direction, source_law, notes)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                i + 1,
                flow["section_number"],
                flow["title_num"],
                flow["amount_text"],
                flow["amount_dollars"],
                flow["amount_unit"],
                flow["direction"],
                flow["source_law"],
                flow["notes"],
            ],
        )
    print(f"  Loaded {len(money_flows)} money flows")


def load_entities(con, entities):
    """Load entity records into DuckDB."""
    for i, entity in enumerate(entities):
        con.execute(
            """INSERT INTO entities
               (id, section_number, title_num, entity_name, entity_type, outcome, detail)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            [
                i + 1,
                entity["section_number"],
                entity["title_num"],
                entity["entity_name"],
                entity["entity_type"],
                entity["outcome"],
                entity["detail"],
            ],
        )
    print(f"  Loaded {len(entities)} entity records")


def generate_report(con, name, query, output_dir):
    """Run a report query, save to JSON."""
    results = con.execute(query).fetchall()
    columns = [desc[0] for desc in con.description]
    rows = [dict(zip(columns, row)) for row in results]

    report = {
        "report": name,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "count": len(rows),
        "data": rows,
    }

    output_path = output_dir / f"{name}.json"
    output_path.write_text(json.dumps(report, indent=2, default=str))
    print(f"  Report '{name}': {len(rows)} rows -> {output_path}")
    return report


REPORTS = {
    "spending": """
        SELECT
            t.title_num,
            t.title_name,
            m.direction,
            COUNT(*) AS provision_count,
            SUM(m.amount_dollars) AS total_dollars
        FROM money_flows m
        JOIN sections s ON m.section_number = s.section_number
        JOIN titles t ON s.title_num = t.title_num
        GROUP BY t.title_num, t.title_name, m.direction
        ORDER BY t.title_num, m.direction
    """,
    "rescissions": """
        SELECT
            m.source_law,
            COUNT(*) AS rescission_count,
            SUM(m.amount_dollars) AS total_rescinded,
            STRING_AGG(DISTINCT m.section_number, ', ' ORDER BY m.section_number) AS sections
        FROM money_flows m
        WHERE m.direction = 'rescission'
        GROUP BY m.source_law
        ORDER BY total_rescinded DESC NULLS LAST
    """,
    "who_loses": """
        SELECT
            e.entity_name,
            e.entity_type,
            COUNT(DISTINCT e.section_number) AS section_count,
            STRING_AGG(DISTINCT t.title_name, ', ' ORDER BY t.title_name) AS titles_affected,
            STRING_AGG(DISTINCT e.section_number, ', ' ORDER BY e.section_number) AS sections
        FROM entities e
        JOIN sections s ON e.section_number = s.section_number
        JOIN titles t ON s.title_num = t.title_num
        WHERE e.outcome = 'loses'
        GROUP BY e.entity_name, e.entity_type
        ORDER BY section_count DESC
    """,
    "who_benefits": """
        SELECT
            e.entity_name,
            e.entity_type,
            COUNT(DISTINCT e.section_number) AS section_count,
            STRING_AGG(DISTINCT t.title_name, ', ' ORDER BY t.title_name) AS titles_affected,
            STRING_AGG(DISTINCT e.section_number, ', ' ORDER BY e.section_number) AS sections
        FROM entities e
        JOIN sections s ON e.section_number = s.section_number
        JOIN titles t ON s.title_num = t.title_num
        WHERE e.outcome = 'benefits'
        GROUP BY e.entity_name, e.entity_type
        ORDER BY section_count DESC
    """,
    "immigration": """
        SELECT
            s.section_number,
            s.section_title,
            t.title_name,
            s.summary
        FROM sections s
        JOIN titles t ON s.title_num = t.title_num
        WHERE LOWER(s.summary) LIKE '%alien%'
           OR LOWER(s.summary) LIKE '%immigrant%'
           OR LOWER(s.summary) LIKE '%non-citizen%'
           OR LOWER(s.summary) LIKE '%asylum%'
           OR LOWER(s.summary) LIKE '%deporta%'
           OR LOWER(s.summary) LIKE '%undocumented%'
           OR LOWER(s.summary) LIKE '%eligib%citizen%'
           OR LOWER(s.mechanism) LIKE '%alien%'
           OR LOWER(s.mechanism) LIKE '%immigrant%'
        ORDER BY t.title_num, s.section_number
    """,
    "spending_by_title": """
        SELECT
            t.title_num,
            t.title_name,
            SUM(CASE WHEN m.direction = 'appropriation' THEN m.amount_dollars ELSE 0 END) AS total_appropriations,
            SUM(CASE WHEN m.direction = 'rescission' THEN m.amount_dollars ELSE 0 END) AS total_rescissions,
            SUM(CASE WHEN m.direction = 'tax_cut' THEN m.amount_dollars ELSE 0 END) AS total_tax_cuts,
            SUM(CASE WHEN m.direction = 'tax_increase' THEN m.amount_dollars ELSE 0 END) AS total_tax_increases,
            COUNT(*) AS flow_count
        FROM money_flows m
        JOIN titles t ON m.title_num = t.title_num
        GROUP BY t.title_num, t.title_name
        ORDER BY t.title_num
    """,
}


def run_pipeline(analysis_dir: str, report_names: list[str] | None = None, parse_only: bool = False):
    """Run the full analytics pipeline."""
    print("=" * 60)
    print("Big Beautiful Bill — Analytics Pipeline")
    print("=" * 60)

    # Step 1: Parse
    print("\n[1/4] Parsing analysis files...")
    parsed = parse_all(analysis_dir)

    # Step 2: Load base data
    print("\n[2/4] Loading into DuckDB...")
    con = init_db(parsed)

    # Step 3: Extract and load
    print("\n[3/4] Extracting structured data...")
    money = extract_money(parsed)
    load_money(con, money)

    entities = extract_entities(parsed)
    load_entities(con, entities)

    if parse_only:
        print("\n[DONE] Parse-only mode. Skipping reports.")
        con.close()
        return

    # Step 4: Generate reports
    print("\n[4/4] Generating reports...")
    output_dir = Path(__file__).parent / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    names = report_names or list(REPORTS.keys())
    for name in names:
        if name in REPORTS:
            generate_report(con, name, REPORTS[name], output_dir)
        else:
            print(f"  WARNING: Unknown report '{name}'")

    con.close()
    print("\n" + "=" * 60)
    print("Pipeline complete.")
    print("=" * 60)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Big Beautiful Bill analytics pipeline")
    ap.add_argument("--report", nargs="*", help="Generate specific reports (default: all)")
    ap.add_argument("--parse-only", action="store_true", help="Parse and load only, skip reports")
    args = ap.parse_args()

    base_dir = Path(__file__).parent.parent
    analysis_dir = str(base_dir / "analysis")

    run_pipeline(analysis_dir, report_names=args.report, parse_only=args.parse_only)
