"""Extract buried provisions from sections."""

import re

HIGH_SIGNIFICANCE_KEYWORDS = [
    "eliminat", "repeal", "terminat", "eliminates", "significant",
    "billion", "million", "retroactive", "unprecedented", "buried",
    "unrelated", "rider", "snuck", "hidden", "disguised",
    "no oversight", "no reporting", "no judicial review",
    "no waiver", "non-waivable",
]

LOW_VALUE_PATTERNS = [
    r"^none\.?$",
    r"^none apparent\.?$",
    r"^none identified\.?$",
    r"^none obvious\.?$",
    r"^n/a\.?$",
    r"^no buried provisions",
    r"^nothing notable",
    r"^none beyond",
]


def extract_buried(section: dict) -> list[dict]:
    """Extract buried provisions from a section."""
    buried_text = section.get("buried", "")
    if not buried_text:
        return []

    buried_text = buried_text.strip()

    # Skip empty/none values
    for pattern in LOW_VALUE_PATTERNS:
        if re.match(pattern, buried_text, re.IGNORECASE):
            return []

    if len(buried_text) < 10:
        return []

    significance = classify_significance(buried_text)

    return [{
        "section_number": section["section_number"],
        "title_num": section["title_num"],
        "description": buried_text,
        "significance": significance,
    }]


def classify_significance(text: str) -> str:
    """Rate significance based on keyword presence."""
    text_lower = text.lower()
    hits = sum(1 for kw in HIGH_SIGNIFICANCE_KEYWORDS if kw in text_lower)

    if hits >= 3:
        return "high"
    elif hits >= 1:
        return "medium"
    return "low"


def extract_all(parsed_files: list[dict]) -> list[dict]:
    """Extract buried provisions from all parsed sections."""
    all_buried = []
    for file_data in parsed_files:
        for section in file_data["sections"]:
            buried = extract_buried(section)
            all_buried.extend(buried)

    print(f"  Extracted {len(all_buried)} buried provision records")
    return all_buried
