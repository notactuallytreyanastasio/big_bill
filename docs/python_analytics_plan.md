# Python/DuckDB Analytics Pipeline — Plan

**Project:** Big Beautiful Bill analysis (Elixir/Phoenix at `/Users/robertgrayson/code/big_bill`)
**Date:** 2026-05-28
**Status:** Pre-implementation plan

---

## 1. Current State Inventory

Before planning forward, here is what already exists and constrains the design:

### Elixir side
- `BigBill.Legislation.Parser` — parses `bigbill.txt` into `%Section{}` structs keyed by section number, title/subtitle/chapter hierarchy, and line range.
- `BigBill.Legislation.Analysis` — typed struct for a structured analysis result: `section_number`, `mechanisms`, `money`, `deadlines`, `beneficiaries`, `losers`, `buried_provisions`, `cross_references`, `tags`, `confidence`.
- `{:duckdbex, "~> 0.3"}` declared in `mix.exs` but not yet wired to any module.
- LiveView pages: `search_live.ex`, `section_live.ex`, `title_live.ex`, `dashboard_live.ex`. Search currently does in-memory substring matching over parsed sections.
- Postgres via docker-compose (no migrations yet in `priv/repo/migrations/`).

### Analysis markdown files (14 files, 9,763 lines total)
All live in `/analysis/` (excluded from git per `.gitignore`). The files use two slightly different structural conventions:

**Convention A** (Titles I, IX, X and most others):
```
### SEC. 10101. TITLE IN CAPS
**Section number and title:** SEC. 10101
**Plain-English summary:** ...
**Mechanism:** ...
**Existing law modified:** ...
**Money:** ...
**Deadlines:** ...
**Who benefits / Who loses:**
- *Loses:* ...
- *Benefits:* ...
**Buried provisions:** ...
**Cross-references:** ...
```

**Convention B** (Title VII chapters — tax, medicaid, green deal):
```
### SEC. 70301 — Title in Mixed Case
**1. Section Number and Title:** ...
**2. Plain-English summary:** ...
**3. Mechanism:** ...
**4. Existing law modified:** ...
**5. Money:** ...
**6. Deadlines:** ...
**7. Who Benefits / Who Loses:** ...
**8. Buried provisions:** ...
```

Both conventions use the same semantic fields. The parser must handle both.

Each file also has a multi-paragraph **Executive Summary** at the top and a **Summary/Conclusion** section at the bottom.

---

## 2. Elixir-Python Integration Options

### Option A: `Pythonx` hex package

`Pythonx` (hex package `pythonx`) embeds CPython directly into the BEAM via NIFs. Python code runs in the same OS process as the Elixir VM.

**Pros:**
- Zero process overhead — no shell spawning, no serialization round-trips for calling individual functions.
- Can pass Elixir terms (lists, maps, binaries) to Python and receive results back as Elixir terms.
- Good fit for tight feedback loops — e.g., calling a Python parser function from a LiveView event handler.

**Cons:**
- A crash or segfault in a native Python extension (`numpy`, `duckdb`'s C layer) can bring down the BEAM. DuckDB's Python binding (`duckdb` package) is a C extension — this is a real risk.
- CPython has a GIL; under Pythonx the GIL is held during Python execution, blocking that BEAM scheduler thread. Long-running analytics queries will stall the scheduler.
- Pythonx is relatively new and not yet battle-tested in production. It works well for short, CPU-light Python calls (e.g., calling `markdown-it-py` to parse a document).
- Adding a full Python environment to the Docker build is more complex — the CPython version is baked in at compile time.

**Verdict for this project:** Pythonx is attractive for simple, fast Python calls (e.g., invoking the markdown parser). It is a poor fit for running DuckDB analytical queries, which are long-running and CPU-intensive.

---

### Option B: Port / `System.cmd` approach

Elixir calls Python scripts via `System.cmd/3` (fire-and-forget, captures stdout/stderr) or via Erlang Ports (bidirectional byte-stream IPC with the Python process).

**`System.cmd` pattern:**
```elixir
System.cmd("python3", ["analytics/pipeline.py", "--report", "who_loses", "--output", "/tmp/report.json"])
```

**Port (bidirectional) pattern:**
```elixir
port = Port.open({:spawn, "python3 analytics/server.py"}, [:binary, :use_stdio])
send(port, {self(), {:command, Jason.encode!(%{action: "query", sql: "SELECT ..."})}})
```

**Pros:**
- Complete process isolation — a DuckDB crash or OOM in Python cannot kill the BEAM.
- Python process runs outside BEAM schedulers; no GIL impact on Elixir throughput.
- Simple mental model for a pipeline: Elixir triggers Python, Python writes JSON or Parquet, Elixir reads results.
- Easy to develop and debug Python scripts independently.
- No special hex dependency.

**Cons:**
- Subprocess startup overhead (~300–500ms for a Python process with `duckdb` loaded). Fine for batch analytics; bad for per-request latency.
- Data passed between processes must be serialized (JSON is the obvious choice).
- Need to manage Python environment (venv, requirements.txt) separately.

**Verdict for this project:** `System.cmd` is the right choice. The analytics pipeline is batch-oriented — it runs on demand (or on a schedule), produces JSON reports, and feeds LiveView. Sub-second response time is not required. Process isolation protects the BEAM from DuckDB's C layer.

---

### Recommended Integration Architecture

Use `System.cmd` for all Python invocations. A thin Elixir module (`BigBill.Analytics`) wraps the calls:

```elixir
defmodule BigBill.Analytics do
  @python_dir Path.join(:code.priv_dir(:big_bill), "../analytics")

  def run_pipeline(args \\ []) do
    cmd_args = ["analytics/pipeline.py" | args]
    System.cmd("python3", cmd_args, cd: @python_dir, stderr_to_stdout: true)
  end

  def load_report(name) do
    path = Path.join([@python_dir, "output", "#{name}.json"])
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, data}
    end
  end
end
```

Python writes JSON files to `analytics/output/`. LiveView reads them via `BigBill.Analytics.load_report/1`. A Mix task (`mix analytics.run`) triggers the full pipeline on demand.

---

## 3. DuckDB Strategy

### Should Python share Elixir's DuckDB instance?

No. They should use separate DuckDB files.

**Reasoning:**
- DuckDB is an embedded single-writer database. Only one process can open a DuckDB file in read-write mode at a time. If both Elixir (via `duckdbex`) and Python (via `duckdb`) open the same file, the second opener will fail with a lock error.
- The Python pipeline is a batch ETL process. It writes the database from scratch each run. This is a different access pattern from Elixir's read queries.
- The cleanest architecture: Python owns the write path; Elixir's `duckdbex` opens the same file in **read-only mode** after the Python pipeline completes.

**File layout:**

| File | Owner | Access |
|------|-------|--------|
| `analytics/db/big_bill.duckdb` | Python (write) | Python reads and writes during pipeline runs |
| `analytics/db/big_bill.duckdb` | Elixir `duckdbex` (read-only) | Opened read-only by Elixir after pipeline runs |

DuckDB supports concurrent read-only connections from multiple processes to the same file. Elixir can safely open the file read-only while Python is not writing.

For the pipeline run itself, Elixir should close its read-only connection (or not open one) while Python is writing, then re-open after. A simple approach: the Mix task that invokes Python also reloads the Elixir DuckDB connection.

---

### Schema Design

The schema mirrors the `BigBill.Legislation.Analysis` struct and the semantic structure of the markdown files. All tables live in a single DuckDB file.

#### `titles`
```sql
CREATE TABLE titles (
    title_num      INTEGER PRIMARY KEY,
    title_name     VARCHAR NOT NULL,
    bill_lines_start INTEGER,
    bill_lines_end   INTEGER,
    analysis_file  VARCHAR   -- e.g., 'title_01_agriculture.md'
);
```

#### `sections`
```sql
CREATE TABLE sections (
    section_number  VARCHAR PRIMARY KEY,  -- e.g., '10101', '70301'
    section_title   VARCHAR NOT NULL,
    title_num       INTEGER REFERENCES titles(title_num),
    subtitle        VARCHAR,
    chapter         VARCHAR,
    summary         VARCHAR,              -- plain-English summary text
    mechanism       VARCHAR,              -- free text from **Mechanism:** field
    existing_law    VARCHAR,              -- free text from **Existing law modified:**
    confidence      VARCHAR,             -- 'high', 'medium', 'low', NULL
    raw_text        VARCHAR              -- full markdown block for that section
);
```

#### `money_flows`
One row per distinct dollar figure or fiscal impact mentioned in a section's **Money:** field.

```sql
CREATE TABLE money_flows (
    id             INTEGER PRIMARY KEY,
    section_number VARCHAR REFERENCES sections(section_number),
    title_num      INTEGER,
    amount_text    VARCHAR,    -- raw text e.g. '$8,000,000,000', '$285M/year'
    amount_dollars DOUBLE,    -- parsed numeric, NULL if unparseable
    amount_unit    VARCHAR,   -- 'annual', 'total', 'per_year', 'one_time', NULL
    direction      VARCHAR,   -- 'appropriation', 'rescission', 'cost_shift', 'tax_cut', 'tax_increase', 'savings', 'unknown'
    source_law     VARCHAR,   -- e.g., 'IRA', 'IIJA', 'CARES', NULL
    notes          VARCHAR    -- e.g., 'CBO estimate', 'author estimate'
);
```

#### `deadlines`
```sql
CREATE TABLE deadlines (
    id             INTEGER PRIMARY KEY,
    section_number VARCHAR REFERENCES sections(section_number),
    deadline_text  VARCHAR,      -- raw text e.g., 'October 1, 2025'
    deadline_date  DATE,         -- parsed, NULL if unparseable
    deadline_type  VARCHAR,      -- 'effective_date', 'sunset', 'reporting', 'election_window', 'expiration', 'other'
    notes          VARCHAR
);
```

#### `entities`
Who wins and who loses. One row per named group or population in a section's beneficiaries/losers fields.

```sql
CREATE TABLE entities (
    id             INTEGER PRIMARY KEY,
    section_number VARCHAR REFERENCES sections(section_number),
    title_num      INTEGER,
    entity_name    VARCHAR,        -- normalized e.g. 'SNAP recipients', 'IRA conservation programs'
    entity_type    VARCHAR,        -- 'population_group', 'agency', 'program', 'industry', 'state', 'other'
    outcome        VARCHAR,        -- 'loses', 'benefits', 'mixed'
    detail         VARCHAR         -- the raw text snippet
);
```

#### `buried_provisions`
```sql
CREATE TABLE buried_provisions (
    id             INTEGER PRIMARY KEY,
    section_number VARCHAR REFERENCES sections(section_number),
    title_num      INTEGER,
    description    VARCHAR NOT NULL,
    significance   VARCHAR     -- 'high', 'medium', 'low' — assigned by parser heuristic
);
```

#### `cross_references`
```sql
CREATE TABLE cross_references (
    id              INTEGER PRIMARY KEY,
    from_section    VARCHAR REFERENCES sections(section_number),
    to_section      VARCHAR,     -- may be a section in this bill or external (e.g., '42 U.S.C. 1396a')
    ref_type        VARCHAR,     -- 'internal', 'external_usc', 'external_cfr', 'external_publaw'
    ref_text        VARCHAR      -- raw reference text
);
```

#### `mechanisms`
Normalized mechanism tags (matches `BigBill.Legislation.Analysis` mechanism type).

```sql
CREATE TABLE mechanisms (
    section_number VARCHAR REFERENCES sections(section_number),
    mechanism      VARCHAR   -- one of the Analysis.mechanism() atom values
);
```

#### `reports`
Cache table for computed cross-cutting reports.

```sql
CREATE TABLE reports (
    report_name    VARCHAR PRIMARY KEY,
    generated_at   TIMESTAMP,
    content_json   VARCHAR    -- JSON blob of the report result
);
```

---

## 4. Python Pipeline Design

### Directory structure

```
analytics/
  pipeline.py          # Main entry point; orchestrates all stages
  parser.py            # Markdown -> structured records
  loader.py            # Inserts records into DuckDB
  extractors/
    money.py           # Dollar amount extraction and classification
    dates.py           # Deadline/effective date parsing
    entities.py        # Entity normalization (who wins/loses)
    crossrefs.py       # Cross-reference parsing and resolution
  reports/
    spending.py        # Spending totals by title and category
    rescissions.py     # Rescissions by source law (IRA, IIJA, other)
    immigration.py     # Alien eligibility restrictions cross-title
    work_requirements.py  # Work requirements inventory
    buried.py          # Buried provisions inventory
    who_loses.py       # "Who loses" rollup by population group
    timeline.py        # Effective dates and sunsets timeline
  output/
    *.json             # Generated report files (read by Elixir)
  db/
    big_bill.duckdb    # DuckDB database file
  requirements.txt
```

### `requirements.txt`

```
duckdb>=0.10.0
markdown-it-py>=3.0.0
python-dateutil>=2.9.0
regex>=2024.0.0
```

No heavy dependencies. No pandas, no numpy. DuckDB handles all the analytics.

---

### `parser.py` — Markdown to structured records

The parser must handle both markdown conventions (A and B described in section 1).

**Algorithm:**

1. Read the markdown file.
2. Split on `### SEC.` to get per-section blocks. Each block starts with the section header line.
3. For each block:
   a. Extract `section_number` from the header line using: `r'SEC\.\s+(\d+)'`
   b. Extract `section_title` — everything after the number on the header line.
   c. For each labeled field (`**Plain-English summary:**`, `**Mechanism:**`, `**Money:**`, `**Deadlines:**`, `**Who benefits / Who loses:**`, `**Buried provisions:**`, `**Cross-references:**`, `**Existing law modified:**`), extract the text that follows until the next labeled field or section boundary.
   d. The numbered-convention variants (`**2. Plain-English summary:**` etc.) are matched by stripping leading digits and dots.
   e. Parse `Who benefits / Who loses:` into separate `beneficiaries` and `losers` lists by splitting on `*Benefits:*` / `*Loses:*` / `- Benefits:` / `- Loses:` markers.
4. Also extract the file-level Executive Summary (text under `## Executive Summary` before the first `### SEC.`).
5. Return a list of `dict` records per section.

**Important parsing notes:**
- Some `**Money:**` fields span multiple lines and contain bullet lists. Capture the entire block, not just the first line.
- `**Deadlines:**` often has a bullet list — collect all bullets as a list.
- Some sections have `**Deadlines:** None specified.` — normalize to empty list.
- Section numbers are 5-digit for most titles (10101, 70301) but may follow different schemes; always treat as strings.

---

### `extractors/money.py` — Dollar amount extraction

The money fields contain a mix of:
- Explicit dollar amounts: `$285,000,000/year`, `$8.45 billion`, `$50+ billion`, `$1.5 billion/year`
- Estimates: `CBO estimated $7.5 billion/year`, `approximately $45 billion`
- Ranges: `$300–600/year per affected beneficiary`
- No direct amount: `No direct appropriation`, `costs flow through...`
- Rescissions: `rescinds approximately $8 billion`

**Extraction strategy:**
1. Run a regex over the money text to find all dollar patterns: `\$[\d,]+(?:\.\d+)?(?:\s*(?:billion|million|trillion))?`
2. Normalize to a float in dollars (handle billion/million multipliers).
3. Classify direction based on context keywords:
   - `rescind`, `rescinds`, `rescission` → `rescission`
   - `appropriated`, `appropriates`, `new funding` → `appropriation`
   - `reduces`, `cuts`, `saves`, `saves approximately` → `savings`
   - `tax cut`, `revenue cost`, `forgone revenue` → `tax_cut`
   - `tax increase`, `raises revenue` → `tax_increase`
   - `cost shift`, `states pay` → `cost_shift`
4. Identify source law by scanning for `Inflation Reduction Act`, `IRA`, `IIJA`, `Infrastructure Investment and Jobs Act`, `CARES`, `ARP` etc.
5. Flag estimates vs. authoritative amounts based on presence of `estimated`, `approximately`, `CBO`, `JCT`.

---

### `extractors/dates.py` — Deadline parsing

1. Extract date-like strings from the deadlines text using `python-dateutil`.
2. Classify each deadline as:
   - `effective_date` — "effective", "begins", "applies to property acquired after"
   - `sunset` — "expires", "sunsets", "terminates", "ends after", "may not be renewed"
   - `reporting` — "quarterly reports", "annual report"
   - `election_window` — "may elect", "election available"
   - `expiration` — program authority ending
3. Handle fiscal year references: "FY2027" → approximate `2026-10-01` to `2027-09-30`.
4. Return list of `(date_string, parsed_date_or_None, deadline_type)` tuples.

---

### `extractors/entities.py` — Entity normalization

The `Who benefits / Who loses:` field is the richest source for "who wins/who loses" analysis but is written in free prose. The goal is a queryable, normalized list of named groups.

**Approach:**
1. Split the text into `loses` and `benefits` halves.
2. Within each half, identify named population groups, agencies, programs, and industries. Use a combination of:
   - Capitalized noun phrases (regex-based)
   - A curated seed dictionary of known entities to normalize variant names:
     - `SNAP recipients` / `SNAP beneficiaries` / `food stamp recipients` → `SNAP recipients`
     - `undocumented immigrants` / `aliens` / `non-LPR immigrants` → `non-citizen immigrants`
     - `Medicaid enrollees` / `Medicaid beneficiaries` → `Medicaid enrollees`
     - IRA conservation programs / Inflation Reduction Act funds → `IRA-funded programs`
   - Do not attempt LLM-based NER — keep this deterministic and auditable.
3. Assign `entity_type`:
   - People/population groups: `population_group`
   - Federal agencies (USDA, CMS, HHS, etc.): `agency`
   - Specific programs (SNAP, LIHTC, § 45Y, EQIP): `program`
   - Industries (EV manufacturers, crop insurance companies): `industry`
   - States or localities: `state`
4. Write one row per unique (section_number, entity_name, outcome) triple.

---

### `extractors/crossrefs.py` — Cross-reference resolution

Cross-reference text contains a mix of internal bill references and external legal citations.

**Classify by pattern:**
- `SEC. 10101` or `SEC. 71109` → `internal` (resolve to `sections.section_number`)
- `42 U.S.C. 1396a`, `7 U.S.C. 2015` → `external_usc`
- `42 C.F.R. § 447.56` → `external_cfr`
- `Public Law 117–169`, `IRA 2022, § 13401` → `external_publaw`

For internal references, validate that the target section number exists in the `sections` table and flag unresolved references.

---

## 5. Specific Reports to Generate

Each report is a Python module in `analytics/reports/` that queries DuckDB and writes a JSON file to `analytics/output/`. All report JSON files follow the same envelope:

```json
{
  "report": "report_name",
  "generated_at": "2026-05-28T12:00:00Z",
  "data": { ... }
}
```

---

### Report 1: `spending.json` — Total spending by title and category

**SQL sketch:**
```sql
SELECT
    t.title_num,
    t.title_name,
    m.direction,
    COUNT(*) AS provision_count,
    SUM(m.amount_dollars) AS total_dollars,
    SUM(CASE WHEN m.amount_dollars IS NULL THEN 1 ELSE 0 END) AS unquantified_count
FROM money_flows m
JOIN sections s ON m.section_number = s.section_number
JOIN titles t ON s.title_num = t.title_num
GROUP BY t.title_num, t.title_name, m.direction
ORDER BY t.title_num, m.direction;
```

Output: table of title × direction × total dollars, with a flag for how many provisions could not be quantified.

---

### Report 2: `rescissions.json` — Rescissions by source law

**SQL sketch:**
```sql
SELECT
    source_law,
    COUNT(*) AS rescission_count,
    SUM(amount_dollars) AS total_rescinded,
    array_agg(section_number ORDER BY section_number) AS sections
FROM money_flows
WHERE direction = 'rescission'
GROUP BY source_law
ORDER BY total_rescinded DESC NULLS LAST;
```

Key categories: IRA (Inflation Reduction Act), IIJA (Infrastructure Investment and Jobs Act), unclassified. This directly answers "how much IRA money is being clawed back and from which programs."

---

### Report 3: `immigration_restrictions.json` — Alien eligibility restrictions cross-title

```sql
SELECT
    s.section_number,
    s.section_title,
    t.title_name,
    e.detail
FROM entities e
JOIN sections s ON e.section_number = s.section_number
JOIN titles t ON s.title_num = t.title_num
WHERE e.entity_name LIKE '%immigrant%'
   OR e.entity_name LIKE '%alien%'
   OR e.entity_name LIKE '%non-citizen%'
   OR e.entity_name LIKE '%DACA%'
   OR e.entity_name LIKE '%undocumented%'
ORDER BY t.title_num, s.section_number;
```

Supplemented by keyword search in `sections.summary` for immigration-related terms. Produces a cross-title inventory of every provision that restricts or removes benefits for immigrants, with the program affected and the estimated population.

---

### Report 4: `work_requirements.json` — Work requirement provisions across titles

Combination query: sections whose `section_title` or `summary` contains "work requirement" or "ABAWD", plus entity rows where `detail` mentions "work requirement". Groups by program (SNAP, Medicaid expansion, other), affected population, effective date, and waiver availability.

---

### Report 5: `buried_provisions.json` — Buried provisions inventory

```sql
SELECT
    b.section_number,
    s.section_title,
    t.title_name,
    b.description,
    b.significance
FROM buried_provisions b
JOIN sections s ON b.section_number = s.section_number
JOIN titles t ON s.title_num = t.title_num
WHERE b.description != 'None.'
  AND b.description != 'None apparent.'
  AND b.description IS NOT NULL
ORDER BY b.significance DESC, t.title_num;
```

The `significance` field is heuristically assigned: "high" if the buried provision text mentions dollar amounts, population counts, or contains words like "significant", "critical", "eliminates", "ends"; "low" otherwise.

---

### Report 6: `who_loses.json` — "Who loses" rollup by population group

```sql
SELECT
    e.entity_name,
    e.entity_type,
    COUNT(DISTINCT e.section_number) AS section_count,
    array_agg(DISTINCT t.title_name ORDER BY t.title_name) AS titles_affected,
    array_agg(e.section_number ORDER BY e.section_number) AS sections
FROM entities e
JOIN sections s ON e.section_number = s.section_number
JOIN titles t ON s.title_num = t.title_num
WHERE e.outcome = 'loses'
GROUP BY e.entity_name, e.entity_type
ORDER BY section_count DESC;
```

This is the top-level "harm inventory" — which groups appear as losers across the most sections and titles.

---

### Report 7: `timeline.json` — Effective dates and sunsets

```sql
SELECT
    d.deadline_date,
    d.deadline_type,
    d.deadline_text,
    d.notes,
    s.section_number,
    s.section_title,
    t.title_name
FROM deadlines d
JOIN sections s ON d.section_number = s.section_number
JOIN titles t ON s.title_num = t.title_num
WHERE d.deadline_date IS NOT NULL
ORDER BY d.deadline_date;
```

Plus a separate bucket for undated deadlines with keywords like "date of enactment", "upon enactment". Produces a chronological timeline usable as a LiveView component.

---

## 6. File Structure in the Elixir Project

```
/Users/robertgrayson/code/big_bill/
  analytics/
    pipeline.py            # Entry point: runs all stages
    parser.py              # Markdown parser
    loader.py              # DuckDB schema creation and data loading
    requirements.txt       # Python deps (duckdb, markdown-it-py, python-dateutil, regex)
    extractors/
      __init__.py
      money.py
      dates.py
      entities.py
      crossrefs.py
    reports/
      __init__.py
      spending.py
      rescissions.py
      immigration.py
      work_requirements.py
      buried.py
      who_loses.py
      timeline.py
    output/                # Generated JSON reports (gitignored)
      .gitkeep
    db/                    # DuckDB database (gitignored)
      .gitkeep
  lib/
    big_bill/
      analytics.ex         # Thin Elixir wrapper: invokes pipeline.py, loads JSON
    big_bill_web/
      live/
        analytics_live.ex  # New LiveView for analytics dashboard
  priv/
    (existing)
```

### `.gitignore` additions needed

```
/analytics/output/
/analytics/db/
/analytics/__pycache__/
/analytics/extractors/__pycache__/
/analytics/reports/__pycache__/
```

---

## 7. Elixir Integration Module (`BigBill.Analytics`)

The module lives at `lib/big_bill/analytics.ex` and exposes three functions:

1. `run_pipeline/0` — Invokes `python3 pipeline.py` via `System.cmd`. Returns `{:ok, output}` or `{:error, output, exit_code}`. Should be called from a Mix task (`mix analytics.run`) and optionally from a LiveView admin button.

2. `load_report/1` — Reads a named report from `analytics/output/*.json` and returns the decoded map.

3. `query/1` — Opens `analytics/db/big_bill.duckdb` read-only via `duckdbex` and runs an ad-hoc SQL query. This enables LiveView to do interactive filtering without re-running the pipeline.

The `duckdbex` dependency (already in `mix.exs`) is used only for `query/1`. The Python pipeline handles all writes.

---

## 8. Mix Task: `mix analytics.run`

Create `lib/mix/tasks/analytics/run.ex`:

```elixir
defmodule Mix.Tasks.Analytics.Run do
  use Mix.Task
  @shortdoc "Run the Python analytics pipeline against the analysis markdown files"

  def run(_args) do
    Mix.shell().info("Running analytics pipeline...")
    case BigBill.Analytics.run_pipeline() do
      {:ok, output} ->
        Mix.shell().info(output)
        Mix.shell().info("Pipeline complete.")
      {:error, output, code} ->
        Mix.shell().error("Pipeline failed (exit #{code}):\n#{output}")
    end
  end
end
```

---

## 9. Implementation Order

The following sequence minimizes wasted effort and produces useful outputs at each step:

1. **Set up Python environment** — Create `analytics/requirements.txt`, confirm `python3 -m venv` works in the project, add `analytics/` dirs to `.gitignore`.

2. **Write `parser.py`** — Parse all 14 markdown files into a list of section dicts. Verify section count matches expectations (compare to `Parser.parse/1` section counts from the Elixir side). This is the foundation; everything else depends on it.

3. **Write `loader.py`** — Create DuckDB schema, load sections table. Verify row counts. At this point, basic SQL queries over sections work.

4. **Write extractors one at a time** — `money.py` first (highest analytical value), then `dates.py`, then `entities.py`, then `crossrefs.py`. Each extractor populates its table.

5. **Write `pipeline.py`** — Wire parser → extractors → loader into a single runnable script with logging.

6. **Write `BigBill.Analytics` Elixir module** and `mix analytics.run` task. Run the pipeline end-to-end.

7. **Write reports one at a time** — Start with `who_loses.py` and `rescissions.py` (highest political salience), then spending, immigration, work requirements, buried provisions, timeline.

8. **Wire reports to LiveView** — Create `analytics_live.ex` with a tabbed interface showing each report. Use `BigBill.Analytics.load_report/1` to feed data.

9. **Add `duckdbex` query path** — Implement `BigBill.Analytics.query/1` for interactive filtering in LiveView.

---

## 10. Key Design Decisions and Rationale

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Elixir-Python integration | `System.cmd` | Process isolation protects BEAM; pipeline is batch, not real-time |
| DuckDB ownership | Python writes, Elixir reads read-only | DuckDB single-writer constraint; clean separation of concerns |
| Database | DuckDB (not Postgres) | Analytics use case — columnar aggregations, no Ecto migrations needed, zero server to manage |
| Parsing approach | Regex over known markdown structure | The markdown is highly structured and machine-generated; regex is faster and auditable |
| Entity normalization | Seeded dictionary + regex, no ML | Deterministic, debuggable, no API calls or model dependency |
| Money parsing | Regex + heuristic direction classifier | The dollar amounts follow recognizable patterns; LLM extraction would be slower and less auditable for a one-time corpus |
| Report format | JSON files on disk | Simple, cache-friendly, no round-trip serialization between Python and Elixir |
| Python environment | venv in `analytics/` | No conda, no Docker-only constraint; matches the existing local dev workflow |

---

## 11. Open Questions Before Implementation

1. **Should the pipeline re-run automatically when analysis files change?** FileSystem watcher (via `fs` hex package) could trigger `mix analytics.run`. Worth discussing before wiring up.

2. **LiveView access control** — Is the analytics dashboard public or admin-only? The current Phoenix app has no auth layer. If this is a personal/research tool, no auth is needed.

3. **Handling the `significance` field for buried provisions** — The plan uses a keyword heuristic. An alternative is to manually curate a short list of the most significant buried provisions (there are not many) and hardcode their significance level. Discuss.

4. **Dollar amount confidence** — Many money fields contain estimates ("CBO estimated", "approximately"). Should the reports prominently distinguish authoritative amounts from estimates? The current schema has a `notes` field but no boolean flag.

5. **Python version pinning** — The local environment uses whatever `python3` is on `PATH`. For the Docker `app` container, Python is not currently installed. If the pipeline needs to run inside Docker, a `Dockerfile.dev` update is needed.
