"""Parse analysis markdown files into structured section records.

Handles both Convention A (Titles I, IX, X) and Convention B (Title VII chapters)
markdown formats. See docs/python_analytics_plan.md for format details.
"""

import re
from pathlib import Path

# Field name patterns — normalized from both conventions
FIELD_PATTERNS = {
    "summary": re.compile(
        r"\*\*(?:\d+\.\s*)?(?:Plain[- ](?:E|e)nglish )?[Ss]ummary[:\s]*\*\*", re.IGNORECASE
    ),
    "mechanism": re.compile(
        r"\*\*(?:\d+\.\s*)?Mechanism[s]?[:\s]*\*\*", re.IGNORECASE
    ),
    "existing_law": re.compile(
        r"\*\*(?:\d+\.\s*)?Existing law (?:modified|changed)[:\s]*\*\*", re.IGNORECASE
    ),
    "money": re.compile(
        r"\*\*(?:\d+\.\s*)?Money[:\s]*\*\*", re.IGNORECASE
    ),
    "deadlines": re.compile(
        r"\*\*(?:\d+\.\s*)?Deadlines?(?:/effective dates?)?[:\s]*\*\*", re.IGNORECASE
    ),
    "who_benefits_loses": re.compile(
        r"\*\*(?:\d+\.\s*)?Who (?:benefits|loses|benefits / Who loses|Benefits / Who Loses)[:\s]*\*\*",
        re.IGNORECASE,
    ),
    "buried": re.compile(
        r"\*\*(?:\d+\.\s*)?Buried provisions?[:\s]*\*\*", re.IGNORECASE
    ),
    "cross_references": re.compile(
        r"\*\*(?:\d+\.\s*)?Cross[- ]references?[:\s]*\*\*", re.IGNORECASE
    ),
    "confidence": re.compile(
        r"\*\*(?:\d+\.\s*)?Confidence[:\s]*\*\*", re.IGNORECASE
    ),
}

SECTION_HEADER = re.compile(r"^#{2,4}\s+(?:SEC\.|Sec\.)\s+(\d+)", re.MULTILINE)


def parse_file(filepath: str) -> dict:
    """Parse a single analysis markdown file.

    Returns dict with 'executive_summary', 'title_info', and 'sections' list.
    """
    text = Path(filepath).read_text(encoding="utf-8")
    filename = Path(filepath).name

    # Extract title number from filename
    title_match = re.search(r"title_(\d+)", filename)
    title_num = int(title_match.group(1)) if title_match else None

    # Split executive summary from sections
    first_section = SECTION_HEADER.search(text)
    executive_summary = ""
    if first_section:
        executive_summary = text[: first_section.start()].strip()

    # Split into section blocks
    section_starts = list(SECTION_HEADER.finditer(text))
    sections = []

    for i, match in enumerate(section_starts):
        sec_num = match.group(1)
        start = match.start()
        end = section_starts[i + 1].start() if i + 1 < len(section_starts) else len(text)
        block = text[start:end]

        # Extract section title from header line
        header_line = block.split("\n")[0]
        sec_title = re.sub(r"^#{2,3}\s+SEC\.\s+\d+[\.\s—–-]*", "", header_line).strip()
        sec_title = sec_title.rstrip("*").strip()

        record = parse_section_block(block, sec_num, sec_title, title_num, filename)
        sections.append(record)

    return {
        "executive_summary": executive_summary,
        "title_num": title_num,
        "filename": filename,
        "sections": sections,
    }


def parse_section_block(block: str, sec_num: str, sec_title: str, title_num: int, filename: str) -> dict:
    """Parse a single section block into a structured record."""
    fields = extract_fields(block)

    beneficiaries, losers = split_benefits_loses(fields.get("who_benefits_loses", ""))

    return {
        "section_number": sec_num,
        "section_title": sec_title,
        "title_num": title_num,
        "source_file": filename,
        "summary": fields.get("summary", "").strip(),
        "mechanism": fields.get("mechanism", "").strip(),
        "existing_law": fields.get("existing_law", "").strip(),
        "money": fields.get("money", "").strip(),
        "deadlines": fields.get("deadlines", "").strip(),
        "beneficiaries": beneficiaries,
        "losers": losers,
        "buried": fields.get("buried", "").strip(),
        "cross_references": fields.get("cross_references", "").strip(),
        "confidence": fields.get("confidence", "").strip(),
        "raw_block": block,
    }


def extract_fields(block: str) -> dict:
    """Extract labeled fields from a section block."""
    # Find all field positions
    positions = []
    for field_name, pattern in FIELD_PATTERNS.items():
        match = pattern.search(block)
        if match:
            positions.append((match.start(), match.end(), field_name))

    positions.sort(key=lambda x: x[0])

    fields = {}
    for i, (start, end, name) in enumerate(positions):
        next_start = positions[i + 1][0] if i + 1 < len(positions) else len(block)
        content = block[end:next_start].strip()
        # Clean up leading colons/whitespace
        content = re.sub(r"^[:\s]+", "", content)
        fields[name] = content

    return fields


def split_benefits_loses(text: str) -> tuple[str, str]:
    """Split who benefits/loses text into two halves."""
    if not text:
        return "", ""

    # Try explicit markers
    benefits = ""
    losers = ""

    benefit_markers = [
        r"\*(?:Benefits|Who benefits)[:\s]*\*",
        r"-\s*(?:Benefits|Who benefits):",
        r"\*\*(?:Benefits|Who benefits)[:\s]*\*\*",
    ]
    loses_markers = [
        r"\*(?:Loses|Who loses)[:\s]*\*",
        r"-\s*(?:Loses|Who loses):",
        r"\*\*(?:Loses|Who loses)[:\s]*\*\*",
    ]

    for marker in benefit_markers:
        m = re.search(marker, text, re.IGNORECASE)
        if m:
            benefits_start = m.end()
            # Find where loses section starts
            for lmarker in loses_markers:
                lm = re.search(lmarker, text[benefits_start:], re.IGNORECASE)
                if lm:
                    benefits = text[benefits_start : benefits_start + lm.start()].strip()
                    losers = text[benefits_start + lm.end() :].strip()
                    return benefits, losers
            benefits = text[benefits_start:].strip()
            return benefits, losers

    # If no markers, try splitting on "Loses:" appearing after "Benefits:"
    for lmarker in loses_markers:
        lm = re.search(lmarker, text, re.IGNORECASE)
        if lm:
            losers = text[lm.end() :].strip()
            benefits = text[: lm.start()].strip()
            return benefits, losers

    # Fallback: return everything as combined
    return text, ""


def parse_all(analysis_dir: str = "analysis") -> list[dict]:
    """Parse all analysis markdown files in the given directory."""
    analysis_path = Path(analysis_dir)
    all_records = []

    for filepath in sorted(analysis_path.glob("title_*.md")):
        result = parse_file(str(filepath))
        all_records.append(result)
        print(f"  Parsed {filepath.name}: {len(result['sections'])} sections")

    total = sum(len(r["sections"]) for r in all_records)
    print(f"Total: {total} sections from {len(all_records)} files")
    return all_records


if __name__ == "__main__":
    import sys

    base_dir = Path(__file__).parent.parent
    results = parse_all(str(base_dir / "analysis"))

    for r in results:
        for s in r["sections"]:
            money = s["money"][:60] + "..." if len(s["money"]) > 60 else s["money"]
            print(f"  SEC. {s['section_number']}: {s['section_title'][:50]}  | ${money}")
