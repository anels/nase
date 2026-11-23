#!/usr/bin/env bash
# Regression tests for the gate/PR helper fixes that only showed on a non-UTF-8
# locale (Windows cp1252) or on unusual input: subprocess decoding, the prose-lint
# emoji gate, background verification runs, secret-scan gaps, and the Confluence
# splitter, emitter, table sizing, browser lookup and attachment listing.
#
# Run from repo root: bash tests/scripts/test-gate-script-portability.sh
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

NASE_TEST_ROOT="$ROOT" python3 - <<'PY'
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(os.environ["NASE_TEST_ROOT"])
SCRIPTS = ROOT / ".claude" / "scripts"
sys.path.insert(0, str(SCRIPTS))
UNDECODABLE_IN_CP1252 = "ā"  # UTF-8 C4 81; cp1252 leaves 0x81 undefined


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def narrow_env() -> dict[str, str]:
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "ascii"
    env.pop("PYTHONUTF8", None)
    return env


class SubprocessDecoding(unittest.TestCase):
    def test_gh_helper_decodes_utf8(self):
        import nase_gh

        done = nase_gh.run(
            [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'\\xc4\\x81')"]
        )
        self.assertEqual(done.stdout, UNDECODABLE_IN_CP1252)

    def test_git_helper_decodes_utf8(self):
        import nase_git

        with tempfile.TemporaryDirectory() as repo:
            subprocess.run(["git", "init", "-q", repo], check=True)
            subprocess.run(
                ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                 "commit", "-q", "--allow-empty", "-m", UNDECODABLE_IN_CP1252],
                check=True,
            )
            done = nase_git.run("log", "-1", "--format=%s", repo=repo, text=True)
            self.assertEqual(done.stdout.strip(), UNDECODABLE_IN_CP1252)
            self.assertIsInstance(nase_git.run("log", "-1", repo=repo).stdout, bytes)

    def test_pr_sweep_survives_missing_stdout(self):
        sweep = load("effort-pr-sweep")
        sweep.run = lambda args: subprocess.CompletedProcess(args, 0, None, "")
        _, state = sweep.read_pr(("o", "r", 1))
        self.assertEqual(state["state"], "UNREADABLE")

    def test_tmp_prune_grep_failures_are_a_failed_scan(self):
        prune = load("tmp-prune")
        real = subprocess.run
        try:
            def missing(*args, **kwargs):
                raise FileNotFoundError("grep")

            prune.subprocess.run = missing
            self.assertIsNone(prune._grep(["x"], []))
            prune.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0, None, None)
            self.assertIsNone(prune._grep(["x"], []))
        finally:
            prune.subprocess.run = real


class ProseLint(unittest.TestCase):
    def lint(self, payload: bytes) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as work:
            draft = Path(work) / "draft.md"
            draft.write_bytes(payload)
            return subprocess.run(
                [sys.executable, str(SCRIPTS / "prose-lint.py"), "--surface", "slack-dm",
                 "--file", str(draft)],
                capture_output=True, env=narrow_env(), check=False,
            )

    def test_emoji_gate_reports_on_a_narrow_locale(self):
        done = self.lint("- \U0001f680 launch it now\n".encode())
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn(b"Result: FAIL", done.stdout)

    def test_invalid_utf8_is_linted_not_a_traceback(self):
        done = self.lint(b"plain \xff text\n")
        self.assertIn(done.returncode, (0, 1))
        self.assertNotIn(b"Traceback", done.stderr)


class ClaimCheck(unittest.TestCase):
    def run_check(self, background: bool) -> str:
        entries = [
            {"message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": "t1", "name": "Bash",
                 "input": {"command": "pytest -q", "run_in_background": background}}]}},
            {"message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "t1", "content": "started", "is_error": False}]}},
            {"message": {"role": "assistant", "content": [
                {"type": "text", "text": "All tests pass, ready to ship."}]}},
        ]
        with tempfile.TemporaryDirectory() as work:
            transcript = Path(work) / "t.jsonl"
            transcript.write_text("\n".join(json.dumps(e) for e in entries) + "\n", encoding="utf-8")
            env = os.environ.copy()
            env.pop("NASE_ROOT", None)
            done = subprocess.run(
                [sys.executable, str(SCRIPTS / "claim-check.py")],
                input=json.dumps({"transcript_path": str(transcript), "session_id": "s1"}),
                capture_output=True, text=True, encoding="utf-8", env=env, check=False,
            )
            return done.stdout

    def test_background_run_is_not_a_passing_run(self):
        self.assertIn("claim-check", self.run_check(background=True))

    def test_foreground_run_still_counts(self):
        self.assertEqual(self.run_check(background=False).strip(), "")


class SecretScan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bundle = load("verify-bundle")

    def test_previously_missed_shapes_are_flagged(self):
        # Fixture values are assembled so no literal credential shape sits in this file.
        opaque = "abcdef0123456789" * 2
        for line in (
            f'SECRET_KEY = "django-insecure-{opaque}"',
            f"aws_secret_access_key = {opaque}",
            f"AWS_SECRET_ACCESS_KEY={opaque}",
            f'token = "{opaque}"',
            f"auth_token: {opaque}",
            f'bearer_token = "{opaque}"',
            f'private_key = "MIIEvQ{opaque}"',
            'passphrase = "correct horse battery staple"',
            "key = sk_" + "live_" + opaque,
            'password = "!@#$%^&*()"',
            'password = "hunter$(x)2"',
        ):
            self.assertIsNotNone(self.bundle.secret_kind(line.encode()), line)

    def test_references_and_fillers_stay_clean(self):
        for line in (
            'password = os.environ["X"]',
            "token = parts[0]",
            "token = next_token()",
            'token = "your_token_placeholder_value_here"',
            "page_token = resp.next",
            'password = "********"',
            "password = ...",
            'password = "Sql-$(openssl rand -hex 16)-Aa1!"',
            'password = "$(cat token).suffix"',
            'password: "pre-$(DbPassword)"',
            "secret_key = settings.SECRET_KEY",
            "private_key = load_pem(path)",
            'access_key_id = "x"',
            "passphrase = getpass.getpass()",
        ):
            self.assertIsNone(self.bundle.secret_kind(line.encode()), line)


class Confluence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.publish = load("confluence-publish")

    def test_heading_inside_a_fence_does_not_split(self):
        text = "# T\n\n## One\n\n```bash\n## not a heading\necho hi\n```\n\n## Two\n\nbody\n"
        _, blocks, _ = self.publish.markdown_blocks(text)
        self.assertEqual([b.heading for b in blocks if b.heading], ["One", "Two"])

    def test_line_offsets_follow_the_html_parser(self):
        from confluence_html_emitter import HtmlPlusEmitter

        source = "<p>a b\x0cc</p>\n<p>d</p>\n"
        emitter = HtmlPlusEmitter(source, [], True)
        self.assertEqual(emitter.line_offsets[:2], [0, source.index("\n") + 1])

    def test_table_widths_follow_spans(self):
        from confluence_markup import size_tables

        table = (
            "<table><tr><th>a</th><th>" + "wide " * 12 + "</th><th>c</th></tr>"
            '<tr><td rowspan="2">x</td><td>y</td><td>z</td></tr>'
            "<tr><td>y2</td><td>z2</td></tr>"
            '<tr><td colspan="2">w</td><td>q</td></tr></table>'
        )
        rows = size_tables(table).split("<tr>")[1:]
        widths = [__import__("re").findall(r'data-colwidth="([^"]+)"', row) for row in rows]
        narrow, wide, last = widths[0]
        self.assertEqual(widths[1], [narrow, wide, last])
        self.assertEqual(widths[2], [wide, last])
        self.assertEqual(widths[3], [f"{narrow},{wide}", last])

    def test_windows_browser_is_found(self):
        if any(os.path.exists(p) for p in (
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        )):
            self.skipTest("a macOS browser takes precedence on this host")
        saved = {k: os.environ.get(k) for k in ("PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA")}
        with tempfile.TemporaryDirectory() as base:
            edge = Path(base, "Microsoft", "Edge", "Application", "msedge.exe")
            edge.parent.mkdir(parents=True)
            edge.write_bytes(b"")
            try:
                for key in saved:
                    os.environ.pop(key, None)
                os.environ["PROGRAMFILES"] = base
                self.assertEqual(self.publish.find_chrome(), str(edge))
            finally:
                for key, value in saved.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value

    def test_attachment_listing_surfaces_auth_failures(self):
        real = self.publish.open_https

        def refuse(code):
            def opener(request, timeout):
                raise urllib.error.HTTPError(request.full_url, code, "x", {}, io.BytesIO(b""))
            return opener

        try:
            self.publish.open_https = refuse(401)
            with self.assertRaises(RuntimeError):
                self.publish.existing_attachments("s.example.invalid", "e", "t", "1")
            self.publish.open_https = refuse(500)
            self.assertEqual(self.publish.existing_attachments("s.example.invalid", "e", "t", "1"), {})
        finally:
            self.publish.open_https = real


class PrHelper(unittest.TestCase):
    def test_graphql_strings_are_not_type_coerced(self):
        helper = load("pr-github-helper")
        args = helper.gh_threads_args({"owner": "true", "repo": "2048", "number": 7}, "null")
        typed = [args[i + 1] for i, flag in enumerate(args) if flag == "-F"]
        self.assertEqual(typed, ["number=7"])
        self.assertNotIn("-F", helper.gh_thread_comments_args("123", "456"))


class ReviewGateState(unittest.TestCase):
    def test_write_state_leaves_no_temp_file(self):
        gate = load("fsd-review-gate")
        with tempfile.TemporaryDirectory() as work:
            target = Path(work) / "sub" / "state.json"
            gate.write_state(target, {"a": 1})
            gate.write_state(target, {"a": 2})
            self.assertEqual(json.loads(target.read_text(encoding="utf-8")), {"a": 2})
            self.assertEqual([p.name for p in target.parent.iterdir()], ["state.json"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
PY
