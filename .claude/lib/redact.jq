def clip($x; $n):
  (($x // "") | tostring) as $s
  | if ($s | length) > $n then ($s[0:$n] + "...") else $s end;

# Secret-bearing key names. Strong words may end a camelCase identifier (clientSecret,
# accessToken). Weak words (pat, pwd, sig) must be a whole segment so compat:, tokenizer
# and path= are left alone.
def scrub:
  tostring
  | gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"; "[REDACTED_PRIVATE_KEY]")
  | gsub("(?i)(?<pre>authorization[\"']?[[:space:]]*[:=][[:space:]]*)(?:bearer|basic|token|digest|negotiate)[[:space:]]+[^[:space:]\"',;]+"; "\(.pre)[REDACTED]")
  | gsub("(?i)(?<pre>\\bbearer[[:space:]]+)[A-Za-z0-9._~+/=-]{8,}"; "\(.pre)[REDACTED]")
  | gsub("(?i)(?<pre>(?:[A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|api[-_]?key|account[-_]?key|access[-_]?key|private[-_]?key|credentials?)|(?<![A-Za-z0-9])(?:pat|pwd|sig|sas))[\"']?[[:space:]]*[:=][[:space:]]*)(?:\"[^\"]*\"|'[^']*'|[^[:space:]\"',;&}]+)"; "\(.pre)[REDACTED_SECRET]")
  | gsub("github_pat_[A-Za-z0-9_]{20,}"; "[REDACTED_GITHUB_TOKEN]")
  | gsub("gh[pousr]_[A-Za-z0-9_]{20,}"; "[REDACTED_GITHUB_TOKEN]")
  | gsub("xox[abposr]-[A-Za-z0-9-]{10,}"; "[REDACTED_SLACK_TOKEN]")
  | gsub("xapp-[0-9]-[A-Za-z0-9-]{10,}"; "[REDACTED_SLACK_TOKEN]")
  | gsub("\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*"; "[REDACTED_JWT]")
  | gsub("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"; "[REDACTED_AWS_KEY_ID]")
  | gsub("(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"; "[REDACTED_API_KEY]")
  | gsub("(?<![A-Za-z0-9])(?:glpat|npm)[-_][A-Za-z0-9_-]{20,}"; "[REDACTED_API_KEY]")
  | gsub("https?://[^[:space:]@/]+:[^[:space:]@/]+@"; "https://[REDACTED]@");
