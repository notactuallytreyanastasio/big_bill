# Continuous Error Listener

Long-running monitor that watches Docker container logs and automatically heals errors as they appear. Uses TDD: diagnose root cause, write a failing test, then fix the source to make it pass.

## Instructions

### Step 1: Start log monitoring

Launch a background Bash agent to tail Docker logs continuously:

```bash
docker compose logs -f --tail=0 2>&1
```

Use `run_in_background: true` so it streams indefinitely.

### Step 2: Enter the watch loop

Poll the background task output every 10 seconds using the Read tool on the output file (or `tail -20` via Bash). On each check:

1. Read the latest log lines since last check
2. Scan for error-level patterns:
   - `[error]` — Elixir Logger errors
   - `** (` — Elixir exceptions (RuntimeError, FunctionClauseError, etc.)
   - `CRASH REPORT` — OTP crash reports
   - `exited with` — process/container exit
   - `(Postgrex.Error)` — database errors
   - `(Ecto.` — Ecto errors (constraint, migration, query)
   - `== Compilation error` — compile failures
   - `FATAL` — Postgres fatal errors
   - `502` / `503` — service unavailable
3. Ignore noise: `[info]`, `[debug]`, healthcheck pings, normal request logs

If no errors found, continue to next poll cycle.

### Step 3: On error detection — triage

When an error is detected:

1. **Log observation to deciduous:**
   ```bash
   deciduous add observation "Listener detected: <error summary>" -c 50
   ```

2. **Classify severity:**
   - **Critical** (app down): crashes, FATAL DB errors, container exits — debug and fix immediately
   - **Error** (degraded): runtime errors, failed requests — debug and fix immediately
   - **Warning** (watch): one-off errors that may self-resolve — wait for 2 more occurrences before acting

3. **For warnings**: Note the error and continue watching. If it repeats 3+ times within 60 seconds, escalate to Error.

### Step 4: Debug — diagnose before fixing

For Critical and Error severity, **always debug before fixing**:

**Phase 1: Parse the error**
- Extract the exception type, message, and full stacktrace
- Identify the crash site (top of stacktrace) and the full call chain

**Phase 2: Read the crash site**
- Open the file at the top of the stacktrace
- Read the FULL function body, not just the error line
- Read the `@spec` and `@type` definitions for that function

**Phase 3: Trace the call chain**
- For each caller in the stacktrace (working down from crash site to entry point):
  - Read the calling function at that file:line
  - Identify what arguments it passed to the next function
  - Check if the data could have been nil, wrong type, wrong shape, or missing a key
  - Check pattern match clauses — does the function handle this input shape?

**Phase 4: Check types and contracts**
- Read `@type`, `@spec`, and `defstruct` for every module involved
- Does the caller's output type match the callee's input type?
- Is there a struct field that could be `nil` but the code assumes it's always present?

**Phase 5: Identify root cause**
- Find the earliest point in the call chain where the fix should go
- This is usually NOT the crash site (symptom) but 1-3 frames down where data diverged from what the code expected

### Step 5: Write a Failing Test (RED)

**Before editing any source code**, write a test that reproduces the exact failure:

1. **Find the right test file** — mirror the source path. `lib/my_app/game/board.ex` → `test/my_app/game/board_test.exs`. Read the existing test file to match conventions (aliases, struct construction, assertion style).

2. **Write a focused test** that:
   - Constructs the exact input data that triggers the bug (the struct/args from the stacktrace)
   - Calls the function at the root cause location
   - Asserts the correct behavior (what SHOULD happen with this input)
   - Uses a descriptive name: `"place_piece/2 handles piece without color field"`

3. **Run it and confirm it fails:**
   ```bash
   mix test test/my_app/game/board_test.exs --only line:<line_number>
   ```
   If it passes, the test doesn't capture the bug — rewrite it.

### Step 6: Fix at Root Cause (GREEN)

1. **Log the action:**
   ```bash
   deciduous add action "Auto-heal: <root cause and fix>. Test added." -c 75 -f "file1.ex,test_file_test.exs"
   deciduous link <observation_id> <action_id> -r "Listener auto-heal"
   ```

2. **Make the minimal source change** that makes the failing test pass
3. **Run the new test again** — it must pass now
4. **Check for regressions** — grep for other callers of the changed function
5. **Run the full suite:**
   ```bash
   mix compile --warnings-as-errors && mix test
   ```
6. The fix syncs automatically via `docker compose watch`. No rebuild needed.

Do NOT create branches, stage files, or commit. Only modify files.

### Step 7: Verify the fix

After the fix syncs:

1. Watch logs for 15 seconds to see if the error recurs
2. **Log outcome to deciduous:**
   ```bash
   # If resolved:
   deciduous add outcome "Auto-healed: <root cause was X, fixed by Y>. Regression test added." -c 95
   deciduous link <action_id> <outcome_id> -r "Fix verified by listener"

   # If still broken:
   deciduous add outcome "Auto-heal failed: <why — was root cause wrong?>" -c 30
   deciduous link <action_id> <outcome_id> -r "Fix did not resolve"
   ```
3. If the same error appears again after fix, go back to Step 4 and re-debug with the new information. The root cause diagnosis was likely wrong — dig deeper. Write a new test targeting the revised understanding.
4. If it fails a second time, do NOT retry. Log a failed outcome and **alert the user**:
   ```
   LISTENER: Could not auto-heal "<error>". Root cause unclear after 2 debug passes. Manual intervention needed.
   ```
   Then continue watching for other errors.

### Step 8: Continue watching

After handling an error (or deciding not to), resume the poll loop from Step 2. Keep watching indefinitely until interrupted.

**Behavioral rules:**
- **Test before fixing** — never edit source without a failing test that reproduces the bug
- **Debug before testing** — never write a test without tracing the call chain first
- Never fix the same error more than twice — escalate to user
- Never weaken or delete existing tests to make them pass — fix the source code
- Never delete or weaken error handling to silence errors
- Always run `mix compile --warnings-as-errors && mix test` (full suite) after the fix
- Log every observation, action, and outcome to deciduous

$ARGUMENTS