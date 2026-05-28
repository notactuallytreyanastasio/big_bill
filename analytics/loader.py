"""Create DuckDB schema and load parsed section data."""

import duckdb
from pathlib import Path

DB_PATH = Path(__file__).parent / "db" / "big_bill.duckdb"

TITLE_DATA = [
    (1, "Agriculture, Nutrition, and Forestry", 515, 2319, "title_01_agriculture.md"),
    (2, "Armed Services", 2320, 3120, "title_02_armed_services.md"),
    (3, "Banking, Housing, and Urban Affairs", 3121, 3172, "title_03_banking.md"),
    (4, "Commerce, Science, and Transportation", 3173, 3746, "title_04_commerce.md"),
    (5, "Energy and Natural Resources", 3747, 4748, "title_05_energy.md"),
    (6, "Environment and Public Works", 4749, 4930, "title_06_environment.md"),
    (7, "Finance", 4931, 15039, "title_07a_tax_ch1_ch2.md"),
    (8, "Health, Education, Labor, and Pensions", 15040, 16435, "title_08_help.md"),
    (9, "Homeland Security and Governmental Affairs", 16436, 16787, "title_09_homeland.md"),
    (10, "Judiciary", 16788, 18920, "title_10_judiciary.md"),
]


def create_schema(con: duckdb.DuckDBPyConnection):
    """Create all tables."""
    con.execute("DROP TABLE IF EXISTS mechanisms CASCADE")
    con.execute("DROP TABLE IF EXISTS cross_references CASCADE")
    con.execute("DROP TABLE IF EXISTS buried_provisions CASCADE")
    con.execute("DROP TABLE IF EXISTS entities CASCADE")
    con.execute("DROP TABLE IF EXISTS deadlines CASCADE")
    con.execute("DROP TABLE IF EXISTS money_flows CASCADE")
    con.execute("DROP TABLE IF EXISTS sections CASCADE")
    con.execute("DROP TABLE IF EXISTS titles CASCADE")
    con.execute("DROP TABLE IF EXISTS reports CASCADE")

    con.execute("""
        CREATE TABLE titles (
            title_num      INTEGER PRIMARY KEY,
            title_name     VARCHAR NOT NULL,
            bill_lines_start INTEGER,
            bill_lines_end   INTEGER,
            analysis_file  VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE sections (
            section_number  VARCHAR PRIMARY KEY,
            section_title   VARCHAR NOT NULL,
            title_num       INTEGER REFERENCES titles(title_num),
            source_file     VARCHAR,
            summary         VARCHAR,
            mechanism       VARCHAR,
            existing_law    VARCHAR,
            confidence      VARCHAR,
            raw_text        VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE money_flows (
            id             INTEGER PRIMARY KEY,
            section_number VARCHAR REFERENCES sections(section_number),
            title_num      INTEGER,
            amount_text    VARCHAR,
            amount_dollars DOUBLE,
            amount_unit    VARCHAR,
            direction      VARCHAR,
            source_law     VARCHAR,
            notes          VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE deadlines (
            id             INTEGER PRIMARY KEY,
            section_number VARCHAR REFERENCES sections(section_number),
            deadline_text  VARCHAR,
            deadline_date  DATE,
            deadline_type  VARCHAR,
            notes          VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE entities (
            id             INTEGER PRIMARY KEY,
            section_number VARCHAR REFERENCES sections(section_number),
            title_num      INTEGER,
            entity_name    VARCHAR,
            entity_type    VARCHAR,
            outcome        VARCHAR,
            detail         VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE buried_provisions (
            id             INTEGER PRIMARY KEY,
            section_number VARCHAR REFERENCES sections(section_number),
            title_num      INTEGER,
            description    VARCHAR NOT NULL,
            significance   VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE cross_references (
            id              INTEGER PRIMARY KEY,
            from_section    VARCHAR REFERENCES sections(section_number),
            to_section      VARCHAR,
            ref_type        VARCHAR,
            ref_text        VARCHAR
        )
    """)

    con.execute("""
        CREATE TABLE reports (
            report_name    VARCHAR PRIMARY KEY,
            generated_at   TIMESTAMP,
            content_json   VARCHAR
        )
    """)


def load_titles(con: duckdb.DuckDBPyConnection):
    """Load title reference data."""
    for row in TITLE_DATA:
        con.execute(
            "INSERT INTO titles VALUES (?, ?, ?, ?, ?)",
            row,
        )


def load_sections(con: duckdb.DuckDBPyConnection, parsed_files: list[dict]):
    """Load section records from parsed analysis files."""
    for file_data in parsed_files:
        for sec in file_data["sections"]:
            con.execute(
                """INSERT OR IGNORE INTO sections
                   (section_number, section_title, title_num, source_file,
                    summary, mechanism, existing_law, confidence, raw_text)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                [
                    sec["section_number"],
                    sec["section_title"],
                    sec["title_num"],
                    sec["source_file"],
                    sec["summary"],
                    sec["mechanism"],
                    sec["existing_law"],
                    sec["confidence"],
                    sec["raw_block"],
                ],
            )


def get_connection(read_only: bool = False) -> duckdb.DuckDBPyConnection:
    """Open a DuckDB connection."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    return duckdb.connect(str(DB_PATH), read_only=read_only)


def init_db(parsed_files: list[dict]) -> duckdb.DuckDBPyConnection:
    """Full initialization: create schema, load titles and sections."""
    con = get_connection()
    create_schema(con)
    load_titles(con)
    load_sections(con, parsed_files)

    sec_count = con.execute("SELECT COUNT(*) FROM sections").fetchone()[0]
    print(f"  Loaded {sec_count} sections into DuckDB")
    return con


if __name__ == "__main__":
    from parser import parse_all

    base_dir = Path(__file__).parent.parent
    parsed = parse_all(str(base_dir / "analysis"))
    con = init_db(parsed)

    # Quick verification
    for row in con.execute(
        "SELECT t.title_num, t.title_name, COUNT(s.section_number) "
        "FROM titles t LEFT JOIN sections s ON t.title_num = s.title_num "
        "GROUP BY t.title_num, t.title_name ORDER BY t.title_num"
    ).fetchall():
        print(f"  Title {row[0]}: {row[1]} — {row[2]} sections")

    con.close()
