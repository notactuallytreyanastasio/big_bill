"""Extract deadlines, effective dates, and sunset clauses from sections."""

import re
from dateutil import parser as dateparser

DEADLINE_TYPES = {
    "effective_date": [
        "effective", "takes effect", "applies to", "beginning on", "starting",
        "shall apply", "in effect", "enacted", "enactment",
    ],
    "sunset": [
        "expires", "sunsets", "terminates", "shall not apply after",
        "ending on", "expiration", "no longer in effect",
    ],
    "reporting": [
        "report", "quarterly", "annual report", "submit", "shall report",
    ],
    "election_window": [
        "may elect", "election", "opt in", "opt out",
    ],
    "compliance": [
        "not later than", "within", "shall comply", "deadline",
        "by the date", "no later than",
    ],
}

# Common date patterns in legislative text
DATE_PATTERNS = [
    # "October 1, 2025" or "October 1, 2025,"
    re.compile(r"((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4})", re.IGNORECASE),
    # "FY2027" or "FY 2027"
    re.compile(r"(FY\s?\d{4})", re.IGNORECASE),
    # "December 31, 2028"
    re.compile(r"(\d{1,2}/\d{1,2}/\d{4})"),
    # "2025 tax year" or "taxable year 2026"
    re.compile(r"(?:tax(?:able)?\s+year\s+)?(\d{4})\s+tax(?:able)?\s+year", re.IGNORECASE),
    re.compile(r"tax(?:able)?\s+year\s+(\d{4})", re.IGNORECASE),
    # "calendar year 2034"
    re.compile(r"calendar\s+year\s+(\d{4})", re.IGNORECASE),
]


def extract_deadlines(section: dict) -> list[dict]:
    """Extract deadline records from a section's deadlines field."""
    deadlines_text = section.get("deadlines", "")
    if not deadlines_text or deadlines_text.strip().lower() in ("none", "none.", "none specified", "none specified.", "n/a", ""):
        return []

    results = []
    seen_dates = set()

    for pattern in DATE_PATTERNS:
        for match in pattern.finditer(deadlines_text):
            date_str = match.group(1).strip().rstrip(",")
            if date_str in seen_dates:
                continue
            seen_dates.add(date_str)

            parsed_date = try_parse_date(date_str)
            context_start = max(0, match.start() - 80)
            context_end = min(len(deadlines_text), match.end() + 80)
            context = deadlines_text[context_start:context_end].lower()
            dtype = classify_deadline(context)

            results.append({
                "section_number": section["section_number"],
                "deadline_text": date_str,
                "deadline_date": parsed_date,
                "deadline_type": dtype,
                "notes": "",
            })

    return results


def try_parse_date(date_str: str):
    """Attempt to parse a date string into a date object."""
    # Handle FY notation
    fy_match = re.match(r"FY\s?(\d{4})", date_str, re.IGNORECASE)
    if fy_match:
        year = int(fy_match.group(1))
        return f"{year - 1}-10-01"

    # Handle tax year / calendar year
    year_match = re.match(r"(\d{4})$", date_str.strip())
    if year_match:
        return f"{year_match.group(1)}-01-01"

    try:
        dt = dateparser.parse(date_str, fuzzy=True)
        if dt:
            return dt.strftime("%Y-%m-%d")
    except (ValueError, OverflowError):
        pass

    return None


def classify_deadline(context: str) -> str:
    """Classify the type of deadline from surrounding context."""
    scores = {}
    for dtype, keywords in DEADLINE_TYPES.items():
        score = sum(1 for kw in keywords if kw in context)
        if score > 0:
            scores[dtype] = score

    if not scores:
        return "other"
    return max(scores, key=scores.get)


def extract_all(parsed_files: list[dict]) -> list[dict]:
    """Extract deadlines from all parsed sections."""
    all_deadlines = []
    for file_data in parsed_files:
        for section in file_data["sections"]:
            deadlines = extract_deadlines(section)
            all_deadlines.extend(deadlines)

    print(f"  Extracted {len(all_deadlines)} deadline records")
    return all_deadlines
