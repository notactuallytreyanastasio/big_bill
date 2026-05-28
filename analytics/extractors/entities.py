"""Extract and normalize who benefits/loses from each section."""

import re

# Seed dictionary for entity normalization
ENTITY_NORMALIZATIONS = {
    r"SNAP (?:recipients|beneficiaries|participants|households)": "SNAP recipients",
    r"food stamp (?:recipients|beneficiaries)": "SNAP recipients",
    r"Medicaid (?:enrollees|beneficiaries|recipients|expansion adults)": "Medicaid enrollees",
    r"Medicare (?:beneficiaries|enrollees|recipients)": "Medicare beneficiaries",
    r"undocumented (?:immigrants|workers|individuals)": "Undocumented immigrants",
    r"non-citizen (?:immigrants|individuals|workers)": "Non-citizen immigrants",
    r"(?:unauthorized|illegal) (?:immigrants|aliens)": "Undocumented immigrants",
    r"lawfully present (?:non-citizens|immigrants)": "Lawfully present non-citizens",
    r"DACA recipients": "DACA recipients",
    r"TPS holders": "TPS holders",
    r"asylum (?:seekers|applicants)": "Asylum seekers",
    r"expansion states?": "Medicaid expansion states",
    r"non-expansion states?": "Non-expansion states",
    r"rural (?:hospitals?|communities|areas)": "Rural communities",
    r"(?:EV|electric vehicle) (?:manufacturers|industry|companies)": "EV industry",
    r"(?:solar|wind|renewable) (?:industry|companies|developers|manufacturers)": "Renewable energy industry",
    r"(?:oil|gas|fossil fuel) (?:industry|companies|producers)": "Fossil fuel industry",
    r"coal (?:industry|companies|producers|miners)": "Coal industry",
    r"pharmaceutical (?:companies|manufacturers|industry)": "Pharmaceutical industry",
    r"(?:crop )?insurance (?:companies|providers|industry)": "Crop insurance industry",
    r"large (?:farm|agricultural) (?:operations|producers|businesses)": "Large agricultural operations",
    r"(?:small|beginning) farmer": "Small/beginning farmers",
    r"high-income (?:earners|individuals|households|taxpayers)": "High-income earners",
    r"low-income (?:individuals|households|workers|families)": "Low-income families",
    r"(?:working|middle)-class (?:families|individuals|households)": "Working/middle-class families",
    r"(?:student loan )?borrowers": "Student loan borrowers",
    r"graduate students": "Graduate students",
    r"nursing home (?:residents|patients)": "Nursing home residents",
    r"(?:defense|military) (?:contractors|industry)": "Defense contractors",
    r"sanctuary (?:cities|states|jurisdictions)": "Sanctuary jurisdictions",
}

ENTITY_TYPE_PATTERNS = {
    "population_group": [
        "recipients", "enrollees", "beneficiaries", "families", "earners",
        "workers", "immigrants", "students", "borrowers", "residents",
        "seekers", "holders", "applicants", "farmers",
    ],
    "agency": [
        "USDA", "CMS", "HHS", "EPA", "IRS", "DOD", "DHS", "ICE", "CBP",
        "CFPB", "SEC", "FDA", "EOIR", "OMB", "Treasury", "USCIS",
    ],
    "program": [
        "SNAP", "Medicaid", "Medicare", "LIHTC", "NMTC", "CHIP",
        "Section 8", "Pell", "TANF",
    ],
    "industry": [
        "industry", "companies", "manufacturers", "producers", "contractors",
        "developers", "insurers",
    ],
    "state": [
        "states", "jurisdictions", "localities", "counties",
    ],
}


def extract_entities(section: dict) -> list[dict]:
    """Extract beneficiary and loser entities from a section."""
    entities = []

    beneficiaries = section.get("beneficiaries", "")
    losers = section.get("losers", "")

    if beneficiaries:
        entities.extend(_extract_from_text(beneficiaries, "benefits", section))
    if losers:
        entities.extend(_extract_from_text(losers, "loses", section))

    # Also check the who_benefits_loses raw field if beneficiaries/losers are empty
    if not beneficiaries and not losers:
        combined = section.get("who_benefits_loses", "")
        if combined:
            entities.extend(_extract_from_text(combined, "mixed", section))

    return entities


def _extract_from_text(text: str, outcome: str, section: dict) -> list[dict]:
    """Extract entity mentions from a text block."""
    entities = []
    seen = set()

    # Try normalized entities first
    for pattern, normalized_name in ENTITY_NORMALIZATIONS.items():
        if re.search(pattern, text, re.IGNORECASE):
            key = (normalized_name, outcome)
            if key not in seen:
                seen.add(key)
                entities.append({
                    "section_number": section["section_number"],
                    "title_num": section["title_num"],
                    "entity_name": normalized_name,
                    "entity_type": _classify_type(normalized_name),
                    "outcome": outcome,
                    "detail": _get_context(text, pattern),
                })

    # Also check for agency mentions
    for agency in ENTITY_TYPE_PATTERNS["agency"]:
        if agency in text:
            key = (agency, outcome)
            if key not in seen:
                seen.add(key)
                entities.append({
                    "section_number": section["section_number"],
                    "title_num": section["title_num"],
                    "entity_name": agency,
                    "entity_type": "agency",
                    "outcome": outcome,
                    "detail": _get_context(text, agency),
                })

    return entities


def _classify_type(entity_name: str) -> str:
    """Classify an entity into a type."""
    name_lower = entity_name.lower()
    for etype, keywords in ENTITY_TYPE_PATTERNS.items():
        for kw in keywords:
            if kw.lower() in name_lower:
                return etype
    return "other"


def _get_context(text: str, pattern: str) -> str:
    """Get surrounding context for an entity mention."""
    match = re.search(pattern, text, re.IGNORECASE)
    if not match:
        return text[:200]
    start = max(0, match.start() - 50)
    end = min(len(text), match.end() + 100)
    return text[start:end].strip()


def extract_all(parsed_files: list[dict]) -> list[dict]:
    """Extract entities from all parsed sections."""
    all_entities = []
    for file_data in parsed_files:
        for section in file_data["sections"]:
            entities = extract_entities(section)
            all_entities.extend(entities)

    print(f"  Extracted {len(all_entities)} entity records")
    return all_entities
