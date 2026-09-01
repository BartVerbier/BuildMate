"""The pure helpers behind the guided laser-entry CLI."""

from tools.pull_scan import _number, _truth_scaffold


def test_number_accepts_both_decimal_styles():
    assert _number("4.62") == 4.62
    assert _number("4,62") == 4.62
    assert _number(" 2,5 ") == 2.5


def test_number_never_guesses():
    assert _number("") is None
    assert _number("  ") is None
    assert _number("about four") is None


def test_scaffold_matches_the_harness_shape():
    record = _truth_scaffold("visit-x")
    assert record["visit_id"] == "visit-x"
    assert record["laser"]["walls_m"] == []  # empty walls => harness ignores it
    for key in ("scan_pattern", "conditions", "painter_estimate"):
        assert key in record
