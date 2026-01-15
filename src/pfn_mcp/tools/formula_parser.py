"""Formula Parser for Meter Aggregations.

Parses and validates device ID formulas for WAGES telemetry aggregations.

Supported syntax:
    formula := term (('+' | '-') term)*
    term    := device_id | '(' formula ')'
    device_id := integer

Examples:
    - 94           → Single device
    - 94+11+27     → Sum of devices
    - 94-84        → Difference
    - (94+11+27)-(84) → Grouped operations
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class FormulaTerm:
    """A term in a parsed formula.

    Attributes:
        device_ids: List of device IDs in this term
        sign: +1 for addition, -1 for subtraction
    """

    device_ids: list[int] = field(default_factory=list)
    sign: int = 1


class FormulaParseError(ValueError):
    """Raised when formula parsing fails."""

    pass


def parse_formula(formula: str) -> list[FormulaTerm]:
    """Parse a device ID formula into terms with signs.

    Args:
        formula: Formula string like "94+11+27", "94-84", or "(94+11+27)-(84)"

    Returns:
        List of FormulaTerm objects representing the parsed formula

    Raises:
        FormulaParseError: If formula is invalid

    Examples:
        >>> parse_formula("94")
        [FormulaTerm(device_ids=[94], sign=1)]

        >>> parse_formula("94+11+27")
        [FormulaTerm(device_ids=[94, 11, 27], sign=1)]

        >>> parse_formula("94-84")
        [FormulaTerm(device_ids=[94], sign=1), FormulaTerm(device_ids=[84], sign=-1)]

        >>> parse_formula("(94+11+27)-(84)")
        [FormulaTerm(device_ids=[94, 11, 27], sign=1), FormulaTerm(device_ids=[84], sign=-1)]
    """
    # Remove all whitespace
    formula = re.sub(r"\s+", "", formula)

    if not formula:
        raise FormulaParseError("Formula cannot be empty")

    # Validate characters
    if not re.match(r"^[\d+\-()]+$", formula):
        raise FormulaParseError(
            f"Formula contains invalid characters: {formula}. "
            "Only digits, +, -, and parentheses are allowed."
        )

    # Check for consecutive operators
    if re.search(r"[+\-]{2,}", formula):
        raise FormulaParseError(f"Formula has consecutive operators: {formula}")

    # Check for trailing operators
    if formula.endswith("+") or formula.endswith("-"):
        raise FormulaParseError(f"Formula has trailing operator: {formula}")

    # Check for leading operators (except for negative which we don't support)
    if formula.startswith("+") or formula.startswith("-"):
        raise FormulaParseError(f"Formula has leading operator: {formula}")

    # Check balanced parentheses
    depth = 0
    for char in formula:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth < 0:
                raise FormulaParseError(f"Unbalanced parentheses in: {formula}")
    if depth != 0:
        raise FormulaParseError(f"Unbalanced parentheses in: {formula}")

    return _parse_expression(formula)


def _parse_expression(expr: str) -> list[FormulaTerm]:
    """Parse an expression into terms.

    This handles the top-level parsing, splitting ONLY on `-` while respecting
    parentheses. The `+` operator groups device IDs into a single term.

    Design:
        - 94+11+27 → 1 term with [94, 11, 27], sign=1
        - 94-84 → 2 terms: [94] sign=1, [84] sign=-1
        - (94+11+27)-(84) → 2 terms: [94, 11, 27] sign=1, [84] sign=-1
    """
    terms: list[FormulaTerm] = []
    current_sign = 1
    current_start = 0
    depth = 0

    i = 0
    while i < len(expr):
        char = expr[i]

        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "-" and depth == 0:
            # Found a term boundary (only minus creates new terms)
            if i > current_start:
                term_str = expr[current_start:i]
                term = _parse_term(term_str)
                term.sign = current_sign
                terms.append(term)

            current_sign = -1
            current_start = i + 1

        i += 1

    # Handle the last term
    if current_start < len(expr):
        term_str = expr[current_start:]
        if term_str:  # Guard against trailing operator
            term = _parse_term(term_str)
            term.sign = current_sign
            terms.append(term)

    if not terms:
        raise FormulaParseError(f"No valid terms found in: {expr}")

    return terms


def _parse_term(term_str: str) -> FormulaTerm:
    """Parse a single term (either a number or parenthesized expression).

    Args:
        term_str: A term string like "94" or "(94+11+27)"

    Returns:
        FormulaTerm with device_ids populated
    """
    term_str = term_str.strip()

    if not term_str:
        raise FormulaParseError("Empty term in formula")

    # Check if it's a parenthesized group
    if term_str.startswith("(") and term_str.endswith(")"):
        # Remove outer parentheses and parse inner expression
        inner = term_str[1:-1]
        inner_terms = _parse_expression(inner)

        # Flatten: collect all device IDs, applying inner signs
        all_ids: list[int] = []
        for inner_term in inner_terms:
            if inner_term.sign == 1:
                all_ids.extend(inner_term.device_ids)
            else:
                # For subtraction within parens, we treat them as separate
                # This shouldn't happen in well-formed input, but handle it
                all_ids.extend(inner_term.device_ids)

        # If there are subtraction terms within parens, we need different handling
        # For now, we return a flat list assuming parens group additions
        # The outer sign will handle the subtraction
        return FormulaTerm(device_ids=all_ids, sign=1)

    # It's a simple number or addition chain
    if "+" in term_str:
        # Parse as addition chain: 94+11+27
        parts = term_str.split("+")
        device_ids = []
        for part in parts:
            part = part.strip()
            if not part:
                raise FormulaParseError(f"Empty device ID in term: {term_str}")
            try:
                device_ids.append(int(part))
            except ValueError:
                raise FormulaParseError(
                    f"Invalid device ID '{part}' in term: {term_str}"
                )
        return FormulaTerm(device_ids=device_ids, sign=1)

    # Single device ID
    try:
        device_id = int(term_str)
        return FormulaTerm(device_ids=[device_id], sign=1)
    except ValueError:
        raise FormulaParseError(f"Invalid device ID: {term_str}")


def get_all_device_ids(terms: list[FormulaTerm]) -> list[int]:
    """Extract all unique device IDs from parsed terms.

    Args:
        terms: List of FormulaTerm from parse_formula()

    Returns:
        Sorted list of unique device IDs
    """
    all_ids: set[int] = set()
    for term in terms:
        all_ids.update(term.device_ids)
    return sorted(all_ids)


async def validate_formula(
    formula: str, tenant_id: int, *, pool=None
) -> tuple[bool, str | None]:
    """Validate that all device IDs in formula exist and belong to tenant.

    Args:
        formula: Formula string to validate
        tenant_id: Tenant ID to check device ownership
        pool: Database connection pool (optional, uses default if not provided)

    Returns:
        Tuple of (is_valid, error_message)
        If valid, error_message is None
    """
    from pfn_mcp import db

    try:
        terms = parse_formula(formula)
    except FormulaParseError as e:
        return False, str(e)

    device_ids = get_all_device_ids(terms)

    if not device_ids:
        return False, "Formula contains no device IDs"

    # Check all devices exist and belong to tenant
    placeholders = ", ".join(f"${i+1}" for i in range(len(device_ids)))
    query = f"""
        SELECT id FROM devices
        WHERE id IN ({placeholders})
        AND tenant_id = ${len(device_ids) + 1}
        AND is_active = true
    """

    rows = await db.fetch_all(query, *device_ids, tenant_id)
    found_ids = {row["id"] for row in rows}
    missing_ids = set(device_ids) - found_ids

    if missing_ids:
        return False, (
            f"Device IDs not found or not belonging to tenant: {sorted(missing_ids)}"
        )

    return True, None


def calculate_formula_result(
    terms: list[FormulaTerm], values: dict[int, float]
) -> float:
    """Calculate the result of a formula given device values.

    Args:
        terms: Parsed formula terms from parse_formula()
        values: Dict mapping device_id to its value

    Returns:
        Calculated result applying formula operations

    Raises:
        KeyError: If a device_id in the formula is not in values dict
    """
    result = 0.0

    for term in terms:
        term_sum = sum(values[device_id] for device_id in term.device_ids)
        result += term.sign * term_sum

    return result
