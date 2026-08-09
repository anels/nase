from pathlib import Path


def test_guard_exists():
    source = Path("src/parser.py").read_text()
    assert "VACUOUS_TEST_CANARY_7724" in source
