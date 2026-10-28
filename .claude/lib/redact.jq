def clip($x; $n):
  (($x // "") | tostring) as $s
  | if ($s | length) > $n then ($s[0:$n] + "...") else $s end;

def scrub:
  tostring
  | gsub("(?i)bearer[[:space:]]+[A-Za-z0-9._~+/=-]+"; "Bearer [REDACTED]")
  | gsub("(?i)(token|api[-_]?key|password|passwd|pwd|secret|pat)[[:space:]]*[:=][[:space:]]*[^[:space:]\"'']+"; "[REDACTED_SECRET]")
  | gsub("gh[pousr]_[A-Za-z0-9_]{20,}"; "[REDACTED_GITHUB_TOKEN]")
  | gsub("sk-[A-Za-z0-9_-]{20,}"; "[REDACTED_API_KEY]")
  | gsub("https?://[^[:space:]@]+:[^[:space:]@]+@"; "https://[REDACTED]@");
