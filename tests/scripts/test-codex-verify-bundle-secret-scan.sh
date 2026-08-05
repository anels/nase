#!/usr/bin/env bash

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

python3 - "$ROOT" <<'PY'
import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(sys.argv[1])
sys.argv[:] = [sys.argv[0]]
BUNDLE = ROOT / ".claude/scripts/codex-verify-bundle.py"
PLACEHOLDER_CREDENTIAL = b'api_key: "' + b"AKIAIOSFODNN7EX" + b'AMPLE1"'

spec = importlib.util.spec_from_file_location("codex_verify_bundle", BUNDLE)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SecretScanTest(unittest.TestCase):
    def test_identifier_echo_is_not_a_credential(self):
        # A named argument or field initializer carries no literal value.
        for source in (
            b"                accessToken: accessToken,\n",
            b"access_token = access_token\n",
            b"client_secret: client_secret,",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_common_default_password_stays_flagged(self):
        key = b"password"
        self.assertEqual(module.secret_kind(key + b"=" + key), "credential-assignment")

    def test_literal_credentials_still_flagged(self):
        # Keep fixture tokens non-contiguous so the scanner can inspect this source file.
        for source in (
            b"password" + b" = " + b'"hunter2sup3rsecret"',
            b"client_secret" + b"=" + b"abcdefgh12345678",
            b"refresh_token" + b": " + b"someOtherIdentifier",
            b"-----BEGIN RSA " + b"PRIVATE KEY-----",
            b"Authorization: " + b"Bearer " + b"abcdefgh1234",
        ):
            with self.subTest(source=source):
                self.assertIsNotNone(module.secret_kind(source))

    def test_identifier_echo_does_not_mask_a_later_secret(self):
        # The scan must keep going past a benign match instead of returning on it.
        source = b"accessToken: accessToken,\n" + b"client_secret" + b"=abcdefgh12345678\n"
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_quoted_self_named_value_is_still_flagged(self):
        source = b"password" + b" = " + b'"password"'
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_placeholder_marker_still_suppresses(self):
        self.assertIsNone(module.secret_kind(PLACEHOLDER_CREDENTIAL))

    def test_placeholder_does_not_mask_a_later_secret(self):
        source = (
            PLACEHOLDER_CREDENTIAL
            + b"\n"
            + b"client_secret"
            + b"=abcdefgh12345678\n"
        )
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_scanner_sources_do_not_trip_their_own_preflight(self):
        for path in (BUNDLE, ROOT / "tests/scripts/test-codex-verify-bundle-secret-scan.sh"):
            with self.subTest(path=path):
                self.assertIsNone(module.secret_kind(path.read_bytes()))


unittest.main(verbosity=1)
PY
