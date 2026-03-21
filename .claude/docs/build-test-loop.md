# Build & Test Iteration Loop

Shared reference for skills that need to build and test after code changes.

---

## Step 1: Command Discovery

Get build and test commands from the repo's KB file (`Build & Run Commands` section) or the repo's `CLAUDE.md`.

If neither has them, infer from project files:

| File found | Convention |
|---|---|
| `package.json` | `npm run build`, `npm test` |
| `Makefile` | `make build`, `make test` |
| `*.sln` | `dotnet build`, `dotnet test` |
| `go.mod` | `go build ./...`, `go test ./...` |
| `.github/workflows/` | Read CI steps for the canonical commands |

If no commands can be determined after checking all sources, stop and ask:
```
question: "What commands should I use to build and test this repo?"
header: "Build & Test Commands"
```

---

## Step 2: Iteration Loop (max 5)

For each iteration:

1. Run the build command. On failure: read the error, identify the root cause, fix it. Do not retry the same fix twice — try a different approach.
2. Run the test command. On failure: read the failure output, fix production code. **Never modify tests to make them pass.**
3. Both pass → proceed.

---

## Step 3: Escalate After 5 Failures

If still failing after 5 iterations: stop, print the last build/test output in full, and ask the user for guidance. Do not commit broken code.
