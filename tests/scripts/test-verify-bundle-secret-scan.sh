#!/usr/bin/env bash

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

python3 - "$ROOT" <<'PY'
import importlib.util
import sys
import time
import unittest
from pathlib import Path


ROOT = Path(sys.argv[1])
sys.argv[:] = [sys.argv[0]]
BUNDLE = ROOT / ".claude/scripts/verify-bundle.py"
PLACEHOLDER_CREDENTIAL = b"api_" + b'key: "' + b"AKIAIOSFODNN7EX" + b'AMPLE1"'

spec = importlib.util.spec_from_file_location("verify_bundle", BUNDLE)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SecretScanTest(unittest.TestCase):
    def test_identifier_echo_is_not_a_credential(self):
        # A named argument or field initializer carries no literal value.
        for source in (
            b"                access" + b"Token" + b": accessToken,\n",
            b"access_" + b"token" + b" = access_token\n",
            b"client_" + b"secret" + b": client_secret,",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_camel_cased_variable_echo_is_not_a_credential(self):
        # A named argument whose value is a differently named variable carries no literal either.
        for source in (
            b"                    access" + b"Token" + b": userAccessToken,\n",
            b"client_" + b"secret" + b": vendorClientSecret",
            b"api_" + b"key" + b" = apiKeyFromConfig",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_unquoted_literal_containing_the_key_word_stays_flagged(self):
        # Lower-case containment is not a camel hump: this is a literal, not a variable reference.
        for source in (
            b"secret" + b"=mysecretvalue1234",
            b"api_key" + b"=myapikeyvalue123",
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_camel_echo_does_not_mask_a_later_secret(self):
        source = b"access" + b"Token: userAccessToken,\n" + b"client_secret" + b"=abcdefgh12345678\n"
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_test_prefix_is_not_a_production_bypass(self):
        for source in (
            b"Access" + b"Token" + b'="test-access-token"',
            b"api_" + b"key" + b'="test_api_key_value"',
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_unbound_test_substring_still_flagged(self):
        for source in (
            b"client_secret" + b' = "attestationKeyABC123"',
            b"client_secret" + b' = "prod-test-secret-ABC123"',
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_common_default_password_stays_flagged(self):
        key = b"password"
        self.assertEqual(module.secret_kind(key + b"=" + key), "credential-assignment")

    def test_literal_credentials_still_flagged(self):
        # Keep fixture tokens non-contiguous so the scanner can inspect this source file.
        for source in (
            b"password" + b" = " + b'"hunter2sup3rsecret"',
            b'"password' + b'": "hunter2sup3rsecret"',
            b"ADMIN_PASSWORD" + b" = " + b'"recovery_canary_4735"',
            b"client_secret" + b"=" + b"abcdefgh12345678",
            b"refresh_token" + b": " + b"someOtherIdentifier",
            b"-----BEGIN RSA " + b"PRIVATE KEY-----",
            b"Authorization: " + b"Bearer " + b"abcdefgh1234",
        ):
            with self.subTest(source=source):
                self.assertIsNotNone(module.secret_kind(source))

    def test_quoted_credentials_are_scanned_as_full_values(self):
        # Short, spaced, Unicode-first, and punctuation-first values are still literals.
        values = (
            b'"two word passphrase"',
            b'"x7!"',
            '"密碼-canary"'.encode(),
            b'":starts-with-punctuation"',
        )
        for value in values:
            with self.subTest(value=value):
                source = b"ADMIN_PASSWORD" + b" = " + value
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_quoted_credential_allows_cpp_style_comment(self):
        source = b"ADMIN_PASSWORD" + b' = "two word canary" // local override'
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_common_trailing_comments_do_not_hide_credentials(self):
        for suffix in (b" /* local override */", b" -- local override"):
            with self.subTest(suffix=suffix):
                source = b"ADMIN_PASSWORD" + b' = "two word canary"' + suffix
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_unquoted_short_unicode_and_punctuation_values_are_flagged(self):
        for value in (b"x7!", "密碼-canary".encode(), b":local-canary"):
            with self.subTest(value=value):
                source = b"ADMIN_PASSWORD" + b"=" + value
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_runtime_references_are_not_literal_credentials(self):
        for source in (
            b"pass" + b"word = os.getenv(\"DB_PASSWORD\")",
            b"ADMIN_PASS" + b"WORD=$DATABASE_PASSWORD",
            b"pass" + b"word=config.password",
            b"pass" + b"word: str",
            b"pass" + b"word = secrets.token_urlsafe(32)",
            b"client_" + b"secret" + b' = vault.get_secret("client-secret")',
            b"pass" + b"word = getpass.getpass()",
            b"pass" + b'word = input("Pass' + b'word: ")',
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_camel_and_pascal_prefixed_keys_are_flagged(self):
        for key in (b"databasePassword", b"DatabasePassword"):
            with self.subTest(key=key):
                self.assertEqual(
                    module.secret_kind(key + b'="production-canary-4831"'),
                    "credential-assignment",
                )

    def test_arbitrary_calls_do_not_hide_hardcoded_values(self):
        for value in (b'evil("literal")', b'SecretStr("hardcoded-secret")', b'str("hardcoded-secret")'):
            with self.subTest(value=value):
                self.assertEqual(
                    module.secret_kind(b"ADMIN_PASS" + b"WORD=" + value),
                    "credential-assignment",
                )

    def test_safe_call_does_not_hide_nested_credential_assignment(self):
        source = (
            b"pass" + b'word = vault.get_secret("locator", '
            + b"client_" + b"secret" + b'="hardcoded-canary-4831")'
        )
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_long_credential_key_still_fails_closed(self):
        key = (b"a" * 129) + b"_PASSWORD"
        self.assertEqual(
            module.secret_kind(key + b'="long-key-canary-4831"'),
            "credential-assignment",
        )

    def test_triple_quoted_and_escaped_json_credentials_are_flagged(self):
        key = b"ADMIN_" + b"PASSWORD"
        triple = b'"' * 3
        escaped = b'{\\"' + key + b'\\":\\"escaped-json-canary-4831\\"}'
        for source in (
            key + b"=" + triple + b"triple-quoted-canary-4831" + triple,
            escaped,
        ):
            with self.subTest(source=source[:32]):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_escaped_prompt_text_is_not_an_assignment(self):
        self.assertIsNone(module.secret_kind(b'input(\\"Pass' + b'word: \\")'))

    def test_short_declaration_and_overlong_quoted_value_fail_closed(self):
        self.assertEqual(
            module.secret_kind(b"ADMIN_PASSWORD" + b' := "short-declaration-canary"'),
            "credential-assignment",
        )
        overlong = b"ADMIN_PASS" + b"WORD=" + b'"' + (b"x" * 4097) + b'"'
        self.assertEqual(module.secret_kind(overlong), "credential-assignment")

    def test_long_quoted_assignment_is_found_across_stream_chunks(self):
        import io

        assignment = b"ADMIN_PASS" + b"WORD=" + b'"' + (b"x" * 4096) + b'"'
        source = (b"a" * (module.SCAN_CHUNK - 33)) + b"\n" + assignment
        self.assertEqual(module.secret_kind(source), "credential-assignment")
        self.assertEqual(module.scan_stream_for_secret(io.BytesIO(source))[0], "credential-assignment")

    def test_large_non_secret_blob_scans_without_regex_backtracking(self):
        source = (b"ordinary_identifier=" + (b"a" * 1024) + b"\n") * 2048
        started = time.monotonic()
        self.assertIsNone(module.secret_kind(source))
        self.assertLess(time.monotonic() - started, 3.0)

    def test_placeholder_word_inside_real_value_does_not_suppress(self):
        source = b"ADMIN_PASSWORD" + b' = "prod-dummy-value-9374"'
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_identifier_echo_does_not_mask_a_later_secret(self):
        # The scan must keep going past a benign match instead of returning on it.
        source = b"access" + b"Token: accessToken,\n" + b"client_secret" + b"=abcdefgh12345678\n"
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_quoted_self_named_value_is_still_flagged(self):
        source = b"password" + b" = " + b'"password"'
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_placeholder_marker_still_suppresses(self):
        self.assertIsNone(module.secret_kind(PLACEHOLDER_CREDENTIAL))
        self.assertIsNone(module.secret_kind(b"pass" + b'word=""'))

    def test_placeholder_does_not_mask_a_later_secret(self):
        source = (
            PLACEHOLDER_CREDENTIAL
            + b"\n"
            + b"client_secret"
            + b"=abcdefgh12345678\n"
        )
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_paren_variable_reference_is_not_a_credential(self):
        # ADO pipeline variables and shell command substitution both use `$(NAME)`; the
        # `$VAR` / `${VAR}` forms alone left every pipeline YAML excerpt flagged.
        for source in (
            b"SNOWFLAKE_" + b"PASSWORD: $(SNOWFLAKE_PASSWORD)",
            b"SNOWSQL_" + b"PWD=$(SNOWSQL_PWD)",
            b"api_" + b"key" + b": $(apiKey)",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_doc_wrapped_reference_is_not_a_credential(self):
        # Markdown and code excerpts wrap the value in backticks, quotes or braces without
        # changing it. A literal cannot acquire a reference shape by losing wrappers.
        for source in (
            b"- Env var: `SNOWSQL_" + b"PWD: $(SNOWSQL_PWD)`",
            b'password' + b'={$sqlPassword}"`',
            b"pass" + b"word=`${DB_PASSWORD}`",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_command_substitution_with_arguments_is_not_a_credential(self):
        # The unquoted branch cut the value at the first space, so an argument-bearing
        # substitution only ever reached the matcher as a `$(az` fragment.
        for source in (
            b"$pass" + b"word = $(az keyvault secret show --query value -o tsv)",
            b"$pass" + b"word = (az keyvault secret show `",
            b"pass" + b"word=$(aws secretsmanager get-secret-value --secret-id db)",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_embedded_command_substitution_is_not_a_credential(self):
        # A value that splices command output into a larger string is generated at run time,
        # so the surrounding literal text cannot make it a hardcoded credential. The
        # full-match forms above only cover a value that IS the substitution.
        for source in (
            b"SQL_TEST_PASS" + b'WORD="Sql-$(openssl rand -hex 16)-Aa1!"',
            b"pass" + b'word="$(cat /run/secrets/db).suffix"',
            b"client_" + b"secret" + b"=prefix-$(vault read -field=value secret/app)",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_empty_or_numeric_substitution_does_not_launder_a_literal(self):
        # `$()` names no command and `$(1)` is a capture reference, so neither proves the
        # value is generated; the literal around them must stay flagged.
        for source in (
            b"pass" + b"word=abcdefgh12345678$()",
            b"client_" + b"secret" + b"=abcdefgh12345678$(1)",
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_embedded_substitution_does_not_mask_a_later_secret(self):
        source = (
            b"SQL_TEST_PASS" + b'WORD="Sql-$(openssl rand -hex 16)-Aa1!"\n'
            + b"client_secret"
            + b"=abcdefgh12345678\n"
        )
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_connection_string_reference_pair_is_not_a_credential(self):
        # The value of a `;`-delimited pair ends at the `;`. Without that cut the span ran on
        # into `Encrypt=false...`, so a referenced password never matched the bare shape.
        for source in (
            b"export CONN=" + b'"Server=db,1433;Pass' + b"word" + b"=${SQL_PASSWORD};Encrypt=false\"",
            b"Pass" + b"word" + b"=$(vault read -field=value secret/db);Encrypt=false",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_literal_in_a_connection_string_pair_stays_flagged(self):
        # Narrowing the span must not launder a literal that sits before the `;`.
        source = b"Pass" + b"word" + b"=abcdefgh12345678;Encrypt=false"
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_parenthesised_literal_is_still_flagged(self):
        # Bare parens are weak evidence: without a command word plus an argument they must
        # not launder a literal.
        for source in (
            b"pass" + b"word = (azurePassword123XY)",
            b"pass" + b'word = "(az)"',
            b"client_" + b"secret" + b" = (abcdefgh12345678)",
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_angle_placeholder_is_not_a_credential(self):
        for source in (
            b'"CacheRefresh' + b'Token": "<cache-refresh-token-value>"',
            b"pass" + b"word=<your-password-here>",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_angle_placeholder_does_not_mask_a_later_secret(self):
        source = (
            b'"CacheRefresh' + b'Token": "<cache-refresh-token-value>"\n'
            + b"client_secret"
            + b"=abcdefgh12345678\n"
        )
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_fail_closed_sentinels_are_not_angle_placeholders(self):
        # The angle-placeholder rule must not absolve the scanner's own unreadable-value
        # sentinels, which are themselves angle-wrapped.
        for reason in (b"<overlong-quoted-value>", b"<unterminated-quoted-value>"):
            with self.subTest(reason=reason):
                self.assertFalse(module.reference_like(reason))
                self.assertFalse(module.is_placeholder_match(b"pass" + b"word=" + reason))

    def test_bracket_redaction_marker_is_a_placeholder(self):
        # A redaction marker is what remains AFTER the secret is removed, so documentation
        # about redaction quotes it constantly. Both the bare form and the Markdown
        # code-span form must be recognised, including trailing sentence punctuation.
        for source in (
            b"pass" + b"word=[REDACTED]",
            b"pass" + b"word=`[REDACTED]`,",
            b"to" + b"ken=[JWT_REDACTED]",
            b"api_" + b"key=[REDACTED_VALUE]",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_bracket_marker_rule_stays_narrow(self):
        # Only the marker shape is absolved. A bracketed literal, a lower-case lookalike, and
        # a marker with a real value appended are all still credential assignments.
        for source in (
            b"pass" + b"word=[NotAMarker_9182]",
            b"pass" + b"word=[redacted_abcdefgh12345678]",
            b"pass" + b"word=[REDACTED]abcdefgh12345678",
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_bracket_marker_does_not_mask_a_later_secret(self):
        source = b"pass" + b"word=[REDACTED]\n" + b"client_secret" + b"=abcdefgh12345678"
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_fail_closed_sentinels_are_not_bracket_markers(self):
        # The marker rule widens the trim set; the unreadable-value sentinels must still
        # fail closed through it.
        for reason in (b"<overlong-quoted-value>", b"<unterminated-quoted-value>"):
            with self.subTest(reason=reason):
                self.assertFalse(module.is_placeholder_match(b"pass" + b"word=" + reason))

    def test_url_credential_position_reference_is_not_a_credential(self):
        # `git clone https://x-access-token:${PAT}@github.com/owner/repo.git` — the value the
        # scanner sees is the reference plus the URL authority and path, so no fullmatch
        # reference rule covers it. Real pipelines keep this line permanently.
        for source in (
            b'"https://x-access-' + b"token:${GITHUB_PAT}@github.com/${REPO_OWNER}/${REPO_NAME}.git\"",
            b"x-access-" + b"token:$GITHUB_PAT@github.com/owner/repo.git",
            b"access_" + b"token:$(SYSTEM_TOKEN)@dev.azure.com/org/project",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_url_credential_position_literal_is_still_flagged(self):
        # The rule requires the reference to START the value. A pasted literal in the same
        # position has no leading reference, and a real token after the `@` is still caught
        # by the known-token pattern.
        self.assertEqual(
            module.secret_kind(b"x-access-" + b"token:abc123secretvalue@github.com/owner/repo.git"),
            "credential-assignment",
        )
        self.assertEqual(
            module.secret_kind(
                b"x-access-" + b"token:${PAT}@github.com/o/" + b"ghp_" + b"a" * 22 + b".git"
            ),
            "known-token",
        )

    def test_prose_shaped_values_are_not_credentials(self):
        # Markdown running text produces incidental `key=` shapes. Each of these values is
        # provably not a credential: no alphanumerics at all, a bare length, or a format
        # placeholder.
        for source in (
            b"contains a bearer token / `Pass" + b"word=...` / api key",
            b"D-SaaS pushed back (Jay: " + b"secret=32 chars)",
            b"printf 'client_secret" + b": %s\n'",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_prose_shapes_do_not_launder_real_values(self):
        # The narrowing above must stay narrow: anything with alphanumerics, anything longer
        # than a length, and anything past the conversion character is still a literal.
        for source in (
            b"password" + b"=abcdefgh12345678",
            b"password" + b"=12345",
            b"password" + b"=%secretvalue123",
            b"client_secret" + b"=...abcdefgh12345678",
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_call_expression_values_are_not_credentials(self):
        # Prose quoting a code line is the common source: the daily log that reported
        # `secret = find_one(...)` failed the workspace scan before this rule.
        for source in (
            b"fails closed on a `client_" + b"secret" + b" = find_one(...)` line",
            b"pass" + b"word = fetch()",
            b"api_" + b"key" + b"=lookup.api_key(...)",
        ):
            with self.subTest(source=source):
                self.assertIsNone(module.secret_kind(source))

    def test_call_expression_rule_stays_narrow(self):
        # An alphanumeric argument keeps the value flagged, so no call wrapper can launder a
        # pasted literal, and a trailing tail is not a call at all.
        for source in (
            b"client_" + b"secret" + b" = wrap(hardcoded-canary-4831)",
            b"pass" + b"word = wrap('hardcoded-canary-4831')",
            b"pass" + b"word = decrypt(letmein12)",
            b"api_" + b"key" + b" = fetch()extra",
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_call_expression_does_not_mask_a_later_secret(self):
        source = (
            b"secret" + b" = find_one(...)\n"
            + b"client_secret" + b'="hardcoded-canary-4831"\n'
        )
        self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_dictionary_password_sample_is_still_flagged(self):
        # A short word+digits value carries no reference or placeholder shape. Accepting it
        # would blind the scanner to exactly the weak credentials it exists to catch.
        for source in (
            b"pass" + b"word=letmein12",
            b"pass" + b"word=trustno1",
        ):
            with self.subTest(source=source):
                self.assertEqual(module.secret_kind(source), "credential-assignment")

    def test_scanner_sources_do_not_trip_their_own_preflight(self):
        for path in (
            BUNDLE,
            ROOT / "tests/scripts/test-verify-bundle-secret-scan.sh",
            ROOT / "tests/hooks/test-stop-backup-safety.sh",
        ):
            with self.subTest(path=path):
                self.assertIsNone(module.secret_kind(path.read_bytes()))


unittest.main(verbosity=1)
PY
