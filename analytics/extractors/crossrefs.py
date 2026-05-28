"""Extract cross-references from sections — both internal bill refs and external law citations."""

import re

# Internal bill section references
INTERNAL_PATTERN = re.compile(r"SEC\.\s*(\d{5,6})", re.IGNORECASE)
# Alternative: "Section 71119" or "Sec. 10102"
INTERNAL_ALT = re.compile(r"(?:Section|Sec\.?)\s+(\d{5,6})", re.IGNORECASE)

# USC citations: "42 U.S.C. 1396a" or "26 USC 224"
USC_PATTERN = re.compile(r"(\d+)\s+U\.?S\.?C\.?\s+(?:§\s*)?(\d+\w*(?:\([a-z0-9]+\))*)", re.IGNORECASE)

# CFR citations: "42 C.F.R. § 447.56" or "45 CFR 155.305"
CFR_PATTERN = re.compile(r"(\d+)\s+C\.?F\.?R\.?\s+(?:§\s*)?(\d+(?:\.\d+)*)", re.IGNORECASE)

# Public Law citations: "P.L. 117-169" or "Public Law 119-21"
PUBLAW_PATTERN = re.compile(r"(?:P\.?L\.?|Public\s+Law)\s+(\d+-\d+)", re.IGNORECASE)

# IRC section citations: "IRC § 163(j)" or "section 45Y of the Internal Revenue Code"
IRC_PATTERN = re.compile(r"(?:IRC|Internal\s+Revenue\s+Code)\s+(?:§\s*|section\s+)?(\d+\w*(?:\([a-z0-9]+\))*)", re.IGNORECASE)


def extract_crossrefs(section: dict) -> list[dict]:
    """Extract cross-references from a section's cross_references field and summary."""
    refs_text = section.get("cross_references", "")
    summary = section.get("summary", "")
    existing_law = section.get("existing_law", "")
    combined = f"{refs_text}\n{summary}\n{existing_law}"

    if not combined.strip():
        return []

    results = []
    seen = set()
    from_section = section["section_number"]

    # Internal bill references
    for pattern in [INTERNAL_PATTERN, INTERNAL_ALT]:
        for match in pattern.finditer(combined):
            target = match.group(1)
            if target == from_section:
                continue
            key = ("internal", target)
            if key not in seen:
                seen.add(key)
                results.append({
                    "from_section": from_section,
                    "to_section": target,
                    "ref_type": "internal",
                    "ref_text": match.group(0).strip(),
                })

    # USC citations
    for match in USC_PATTERN.finditer(combined):
        title_num = match.group(1)
        section_num = match.group(2)
        ref = f"{title_num} U.S.C. {section_num}"
        key = ("external_usc", ref)
        if key not in seen:
            seen.add(key)
            results.append({
                "from_section": from_section,
                "to_section": ref,
                "ref_type": "external_usc",
                "ref_text": match.group(0).strip(),
            })

    # CFR citations
    for match in CFR_PATTERN.finditer(combined):
        title_num = match.group(1)
        section_num = match.group(2)
        ref = f"{title_num} C.F.R. {section_num}"
        key = ("external_cfr", ref)
        if key not in seen:
            seen.add(key)
            results.append({
                "from_section": from_section,
                "to_section": ref,
                "ref_type": "external_cfr",
                "ref_text": match.group(0).strip(),
            })

    # Public Law citations
    for match in PUBLAW_PATTERN.finditer(combined):
        ref = f"P.L. {match.group(1)}"
        key = ("external_publaw", ref)
        if key not in seen:
            seen.add(key)
            results.append({
                "from_section": from_section,
                "to_section": ref,
                "ref_type": "external_publaw",
                "ref_text": match.group(0).strip(),
            })

    # IRC citations
    for match in IRC_PATTERN.finditer(combined):
        ref = f"26 U.S.C. {match.group(1)}"
        key = ("external_usc", ref)
        if key not in seen:
            seen.add(key)
            results.append({
                "from_section": from_section,
                "to_section": ref,
                "ref_type": "external_usc",
                "ref_text": match.group(0).strip(),
            })

    return results


def extract_all(parsed_files: list[dict]) -> list[dict]:
    """Extract cross-references from all parsed sections."""
    all_refs = []
    for file_data in parsed_files:
        for section in file_data["sections"]:
            refs = extract_crossrefs(section)
            all_refs.extend(refs)

    print(f"  Extracted {len(all_refs)} cross-reference records")
    return all_refs
