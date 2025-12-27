"""Telemetry tools - Phase 2 time-series data access."""

import logging

from pfn_mcp import db

logger = logging.getLogger(__name__)


async def resolve_device(
    search: str,
    tenant_id: int | None = None,
    limit: int = 5,
) -> dict:
    """
    Resolve device search to ranked candidates with match confidence.

    Used before telemetry queries to confirm device selection when
    the search term could match multiple devices.

    Args:
        search: Device name search term
        tenant_id: Optional tenant filter
        limit: Maximum candidates to return

    Returns:
        Dict with search term, candidates list, and match summary
    """
    search_term = search.strip()
    search_lower = search_term.lower()

    conditions = ["d.is_active = true"]
    params = []
    param_idx = 1

    # Tenant filter
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${param_idx}")
        params.append(tenant_id)
        param_idx += 1

    # Search filter - match display_name or device_name
    conditions.append(
        f"(d.display_name ILIKE ${param_idx} OR d.device_name ILIKE ${param_idx})"
    )
    params.append(f"%{search_term}%")
    param_idx += 1

    # Calculate match confidence in SQL for ranking
    # confidence: 0=exact, 1=starts_with, 2=word_boundary, 3=contains (fuzzy)
    confidence_case = f"""
        CASE
            WHEN LOWER(d.display_name) = ${param_idx} THEN 0
            WHEN LOWER(d.display_name) LIKE ${param_idx} || ' %' THEN 1
            WHEN LOWER(d.display_name) LIKE '% ' || ${param_idx} || ' %' THEN 2
            WHEN LOWER(d.display_name) LIKE '% ' || ${param_idx} THEN 2
            WHEN LOWER(d.display_name) LIKE ${param_idx} || '%' THEN 1
            ELSE 3
        END
    """
    params.append(search_lower)
    param_idx += 1

    where_clause = " AND ".join(conditions)

    query = f"""
        SELECT
            d.id,
            d.device_code,
            d.device_name,
            d.display_name,
            d.device_type,
            d.tenant_id,
            t.tenant_name,
            t.tenant_code,
            {confidence_case} as match_confidence
        FROM devices d
        LEFT JOIN tenants t ON d.tenant_id = t.id
        WHERE {where_clause}
        ORDER BY match_confidence, d.display_name
        LIMIT ${param_idx}
    """
    params.append(limit)

    rows = await db.fetch_all(query, *params)

    # Convert confidence numbers to labels
    confidence_labels = {
        0: "exact",
        1: "partial",
        2: "partial",
        3: "fuzzy",
    }

    candidates = []
    for row in rows:
        conf_num = row.get("match_confidence", 3)
        candidates.append({
            "id": row["id"],
            "display_name": row.get("display_name") or row.get("device_name"),
            "device_code": row["device_code"],
            "device_type": row.get("device_type"),
            "tenant_id": row["tenant_id"],
            "tenant_name": row.get("tenant_name"),
            "match_confidence": confidence_labels.get(conf_num, "fuzzy"),
        })

    # Determine if disambiguation is needed
    needs_disambiguation = (
        len(candidates) == 0
        or len(candidates) > 1
        or (len(candidates) == 1 and candidates[0]["match_confidence"] != "exact")
    )

    return {
        "search": search_term,
        "tenant_filter": tenant_id,
        "candidates": candidates,
        "count": len(candidates),
        "needs_disambiguation": needs_disambiguation,
        "exact_match": (
            len(candidates) == 1 and candidates[0]["match_confidence"] == "exact"
        ),
    }


def format_resolve_device_response(result: dict) -> str:
    """Format resolve_device response for human-readable output."""
    search = result["search"]
    candidates = result["candidates"]
    count = result["count"]

    if count == 0:
        return f"No devices found matching '{search}'."

    # Check for exact single match
    if result.get("exact_match"):
        device = candidates[0]
        return (
            f"Found exact match for '{search}':\n\n"
            f"**{device['display_name']}** (ID: {device['id']})\n"
            f"Tenant: {device['tenant_name']}\n"
            f"Type: {device['device_type'] or '-'}\n\n"
            f"Ready to query telemetry with device_id={device['id']}"
        )

    # Multiple matches - format for disambiguation
    lines = [f"Found {count} device(s) matching '{search}':\n"]

    for i, device in enumerate(candidates, 1):
        conf = device["match_confidence"].upper()
        tenant = device["tenant_name"] or "Unknown"
        lines.append(
            f"{i}. **{device['display_name']}** (ID: {device['id']}) "
            f"- {tenant} [{conf}]"
        )
        if device["device_type"]:
            lines.append(f"   Type: {device['device_type']}")

    lines.append("\nPlease specify which device you mean, or use the device ID directly.")

    return "\n".join(lines)
