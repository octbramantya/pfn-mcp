"""Unit tests for formula parser.

Tests for src/pfn_mcp/tools/formula_parser.py
"""

import pytest

from pfn_mcp.tools.formula_parser import (
    FormulaTerm,
    FormulaParseError,
    calculate_formula_result,
    get_all_device_ids,
    parse_formula,
)


class TestParseFormulaSingleDevice:
    """Tests for parsing single device formulas."""

    def test_single_device(self):
        """Parse single device ID."""
        result = parse_formula("94")
        assert len(result) == 1
        assert result[0].device_ids == [94]
        assert result[0].sign == 1

    def test_single_device_with_whitespace(self):
        """Parse single device ID with whitespace."""
        result = parse_formula("  94  ")
        assert len(result) == 1
        assert result[0].device_ids == [94]

    def test_large_device_id(self):
        """Parse large device ID."""
        result = parse_formula("99999")
        assert result[0].device_ids == [99999]


class TestParseFormulaAddition:
    """Tests for parsing addition formulas."""

    def test_two_device_addition(self):
        """Parse addition of two devices."""
        result = parse_formula("94+11")
        assert len(result) == 1
        assert set(result[0].device_ids) == {94, 11}
        assert result[0].sign == 1

    def test_three_device_addition(self):
        """Parse addition of three devices."""
        result = parse_formula("94+11+27")
        assert len(result) == 1
        assert set(result[0].device_ids) == {94, 11, 27}
        assert result[0].sign == 1

    def test_addition_with_whitespace(self):
        """Parse addition formula with whitespace."""
        result = parse_formula(" 94 + 11 + 27 ")
        assert len(result) == 1
        assert set(result[0].device_ids) == {94, 11, 27}


class TestParseFormulaSubtraction:
    """Tests for parsing subtraction formulas."""

    def test_simple_subtraction(self):
        """Parse subtraction of two devices."""
        result = parse_formula("94-84")
        assert len(result) == 2
        assert result[0].device_ids == [94]
        assert result[0].sign == 1
        assert result[1].device_ids == [84]
        assert result[1].sign == -1

    def test_subtraction_with_whitespace(self):
        """Parse subtraction formula with whitespace."""
        result = parse_formula(" 94 - 84 ")
        assert len(result) == 2
        assert result[0].device_ids == [94]
        assert result[1].device_ids == [84]

    def test_multiple_subtractions(self):
        """Parse formula with multiple subtractions."""
        result = parse_formula("100-50-25")
        assert len(result) == 3
        assert result[0].device_ids == [100]
        assert result[0].sign == 1
        assert result[1].device_ids == [50]
        assert result[1].sign == -1
        assert result[2].device_ids == [25]
        assert result[2].sign == -1


class TestParseFormulaGrouped:
    """Tests for parsing grouped (parenthesized) formulas."""

    def test_grouped_addition_minus_single(self):
        """Parse (94+11+27)-(84)."""
        result = parse_formula("(94+11+27)-(84)")
        assert len(result) == 2
        assert set(result[0].device_ids) == {94, 11, 27}
        assert result[0].sign == 1
        assert result[1].device_ids == [84]
        assert result[1].sign == -1

    def test_grouped_both_sides(self):
        """Parse (94+11)-(27+84)."""
        result = parse_formula("(94+11)-(27+84)")
        assert len(result) == 2
        assert set(result[0].device_ids) == {94, 11}
        assert result[0].sign == 1
        assert set(result[1].device_ids) == {27, 84}
        assert result[1].sign == -1

    def test_single_in_parens(self):
        """Parse single device in parentheses."""
        result = parse_formula("(94)")
        assert len(result) == 1
        assert result[0].device_ids == [94]


class TestParseFormulaErrors:
    """Tests for formula parsing error cases."""

    def test_empty_formula(self):
        """Reject empty formula."""
        with pytest.raises(FormulaParseError, match="cannot be empty"):
            parse_formula("")

    def test_whitespace_only(self):
        """Reject whitespace-only formula."""
        with pytest.raises(FormulaParseError, match="cannot be empty"):
            parse_formula("   ")

    def test_consecutive_plus(self):
        """Reject consecutive plus operators."""
        with pytest.raises(FormulaParseError, match="consecutive operators"):
            parse_formula("94++11")

    def test_consecutive_minus(self):
        """Reject consecutive minus operators."""
        with pytest.raises(FormulaParseError, match="consecutive operators"):
            parse_formula("94--11")

    def test_plus_minus(self):
        """Reject plus followed by minus."""
        with pytest.raises(FormulaParseError, match="consecutive operators"):
            parse_formula("94+-11")

    def test_non_numeric(self):
        """Reject non-numeric IDs."""
        with pytest.raises(FormulaParseError, match="invalid characters"):
            parse_formula("abc+123")

    def test_unbalanced_open_paren(self):
        """Reject unbalanced open parenthesis."""
        with pytest.raises(FormulaParseError, match="Unbalanced"):
            parse_formula("(94+11")

    def test_unbalanced_close_paren(self):
        """Reject unbalanced close parenthesis."""
        with pytest.raises(FormulaParseError, match="Unbalanced"):
            parse_formula("94+11)")

    def test_invalid_characters(self):
        """Reject invalid characters."""
        with pytest.raises(FormulaParseError, match="invalid characters"):
            parse_formula("94*11")

    def test_trailing_operator(self):
        """Handle trailing operator gracefully."""
        with pytest.raises(FormulaParseError):
            parse_formula("94+")


class TestGetAllDeviceIds:
    """Tests for get_all_device_ids function."""

    def test_single_term(self):
        """Extract IDs from single term."""
        terms = [FormulaTerm(device_ids=[94, 11, 27], sign=1)]
        result = get_all_device_ids(terms)
        assert result == [11, 27, 94]  # Sorted

    def test_multiple_terms(self):
        """Extract IDs from multiple terms."""
        terms = [
            FormulaTerm(device_ids=[94, 11], sign=1),
            FormulaTerm(device_ids=[84], sign=-1),
        ]
        result = get_all_device_ids(terms)
        assert result == [11, 84, 94]  # Sorted, unique

    def test_duplicate_ids(self):
        """Handle duplicate IDs across terms."""
        terms = [
            FormulaTerm(device_ids=[94, 11], sign=1),
            FormulaTerm(device_ids=[94, 27], sign=1),
        ]
        result = get_all_device_ids(terms)
        assert result == [11, 27, 94]  # Duplicates removed


class TestCalculateFormulaResult:
    """Tests for calculate_formula_result function."""

    def test_single_device(self):
        """Calculate single device value."""
        terms = [FormulaTerm(device_ids=[94], sign=1)]
        values = {94: 100.0}
        result = calculate_formula_result(terms, values)
        assert result == 100.0

    def test_addition(self):
        """Calculate sum of devices."""
        terms = [FormulaTerm(device_ids=[94, 11, 27], sign=1)]
        values = {94: 100.0, 11: 50.0, 27: 25.0}
        result = calculate_formula_result(terms, values)
        assert result == 175.0

    def test_subtraction(self):
        """Calculate difference of devices."""
        terms = [
            FormulaTerm(device_ids=[94], sign=1),
            FormulaTerm(device_ids=[84], sign=-1),
        ]
        values = {94: 100.0, 84: 40.0}
        result = calculate_formula_result(terms, values)
        assert result == 60.0

    def test_complex_formula(self):
        """Calculate complex formula (94+11+27)-(84)."""
        terms = [
            FormulaTerm(device_ids=[94, 11, 27], sign=1),
            FormulaTerm(device_ids=[84], sign=-1),
        ]
        values = {94: 100.0, 11: 50.0, 27: 25.0, 84: 40.0}
        result = calculate_formula_result(terms, values)
        assert result == 135.0  # (100+50+25) - 40

    def test_negative_result(self):
        """Calculate formula resulting in negative value."""
        terms = [
            FormulaTerm(device_ids=[84], sign=1),
            FormulaTerm(device_ids=[94], sign=-1),
        ]
        values = {94: 100.0, 84: 40.0}
        result = calculate_formula_result(terms, values)
        assert result == -60.0

    def test_float_precision(self):
        """Calculate with float values."""
        terms = [
            FormulaTerm(device_ids=[1, 2], sign=1),
            FormulaTerm(device_ids=[3], sign=-1),
        ]
        values = {1: 10.5, 2: 20.25, 3: 5.75}
        result = calculate_formula_result(terms, values)
        assert result == pytest.approx(25.0)

    def test_missing_device_raises(self):
        """Raise KeyError for missing device value."""
        terms = [FormulaTerm(device_ids=[94, 11], sign=1)]
        values = {94: 100.0}  # Missing 11
        with pytest.raises(KeyError):
            calculate_formula_result(terms, values)


class TestRealWorldFormulas:
    """Tests using real-world formula examples from PRS/IOP."""

    def test_prs_facility(self):
        """PRS facility formula: 94+11+27."""
        result = parse_formula("94+11+27")
        assert len(result) == 1
        assert set(result[0].device_ids) == {94, 11, 27}

        values = {94: 5000.0, 11: 200.0, 27: 100.0}
        total = calculate_formula_result(result, values)
        assert total == 5300.0

    def test_prs_yarn_division(self):
        """PRS yarn division formula: 94-84."""
        result = parse_formula("94-84")
        assert len(result) == 2

        values = {94: 5000.0, 84: 3000.0}
        yarn = calculate_formula_result(result, values)
        assert yarn == 2000.0

    def test_iop_facility(self):
        """IOP facility formula: 108 (single meter)."""
        result = parse_formula("108")
        assert len(result) == 1
        assert result[0].device_ids == [108]

    def test_iop_indosena(self):
        """IOP indosena formula: 134+109+110."""
        result = parse_formula("134+109+110")
        assert len(result) == 1
        assert set(result[0].device_ids) == {134, 109, 110}
