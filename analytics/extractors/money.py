"""Extract and classify dollar amounts from section money fields."""

import re

# Dollar amount patterns
DOLLAR_PATTERN = re.compile(
    r"\$\s*([\d,]+(?:\.\d+)?)\s*"
    r"(?:(billion|million|trillion|B|M|T))?"
    r"(?:\s*(?:per\s+year|/year|/yr|annually))?"
    , re.IGNORECASE
)

MULTIPLIERS = {
    "billion": 1_000_000_000,
    "b": 1_000_000_000,
    "million": 1_000_000,
    "m": 1_000_000,
    "trillion": 1_000_000_000_000,
    "t": 1_000_000_000_000,
}

DIRECTION_KEYWORDS = {
    "rescission": ["rescind", "rescinds", "rescission", "rescinded", "clawed back", "clawback"],
    "appropriation": [
        "appropriated", "appropriates", "appropriation", "new funding",
        "new mandatory", "new spending", "authorized", "shall be available",
    ],
    "tax_cut": [
        "tax cut", "revenue cost", "forgone revenue", "revenue loss",
        "deduction", "exclusion", "credit", "exemption",
    ],
    "tax_increase": [
        "tax increase", "raises revenue", "revenue raiser", "new tax",
        "excise tax", "fee", "surcharge",
    ],
    "savings": ["reduces", "saves", "savings", "reduces spending", "cost reduction"],
    "cost_shift": ["states pay", "cost shift", "state share", "cost sharing", "state match"],
}

SOURCE_LAW_PATTERNS = {
    "IRA": ["Inflation Reduction Act", "IRA", "P.L. 117-169", "P.L. 117–169"],
    "IIJA": ["Infrastructure Investment", "IIJA", "BIL", "P.L. 117-58", "P.L. 117–58"],
    "CARES": ["CARES Act", "P.L. 116-136"],
    "ARP": ["American Rescue Plan", "ARP", "P.L. 117-2"],
    "TCJA": ["Tax Cuts and Jobs", "TCJA", "P.L. 115-97"],
    "CHIPS": ["CHIPS", "P.L. 117-167"],
}


def extract_money(section: dict) -> list[dict]:
    """Extract money flows from a section's money field and full text."""
    money_text = section.get("money", "")
    if not money_text or money_text.strip().lower() in ("none", "none.", "n/a", ""):
        return []

    # Also check the summary and raw block for dollar amounts
    full_text = f"{money_text}\n{section.get('summary', '')}"

    amounts = []
    seen = set()

    for match in DOLLAR_PATTERN.finditer(full_text):
        raw_num = match.group(1).replace(",", "")
        multiplier_word = match.group(2)

        try:
            value = float(raw_num)
        except ValueError:
            continue

        if multiplier_word:
            mult = MULTIPLIERS.get(multiplier_word.lower(), 1)
            value *= mult

        # Deduplicate by rounded dollar amount
        rounded = round(value)
        if rounded in seen or rounded == 0:
            continue
        seen.add(rounded)

        # Get surrounding context for classification
        start = max(0, match.start() - 100)
        end = min(len(full_text), match.end() + 100)
        context = full_text[start:end].lower()

        direction = classify_direction(context, section)
        source_law = identify_source_law(full_text)

        is_annual = bool(re.search(r"per\s+year|/year|/yr|annually|per\s+annum", context))

        amounts.append({
            "section_number": section["section_number"],
            "title_num": section["title_num"],
            "amount_text": match.group(0).strip(),
            "amount_dollars": value,
            "amount_unit": "annual" if is_annual else "total",
            "direction": direction,
            "source_law": source_law,
            "notes": "",
        })

    return amounts


def classify_direction(context: str, section: dict) -> str:
    """Classify whether a dollar amount is spending, cutting, etc."""
    mechanism = section.get("mechanism", "").lower()
    full_context = f"{context} {mechanism}"

    scores = {}
    for direction, keywords in DIRECTION_KEYWORDS.items():
        score = sum(1 for kw in keywords if kw in full_context)
        if score > 0:
            scores[direction] = score

    if not scores:
        return "unknown"

    return max(scores, key=scores.get)


def identify_source_law(text: str) -> str | None:
    """Identify if the money relates to a specific prior law."""
    for law_name, patterns in SOURCE_LAW_PATTERNS.items():
        for pattern in patterns:
            if pattern.lower() in text.lower():
                return law_name
    return None


def extract_all(parsed_files: list[dict]) -> list[dict]:
    """Extract money flows from all parsed sections."""
    all_flows = []
    for file_data in parsed_files:
        for section in file_data["sections"]:
            flows = extract_money(section)
            all_flows.extend(flows)

    print(f"  Extracted {len(all_flows)} money flows")
    return all_flows
