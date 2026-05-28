# Self-Healing Server Monitor

Monitor the Docker containers, diagnose errors using structured debugging, write a failing test that reproduces the bug, then fix the source to make it pass.

## Instructions

### Step 1: Launch the server monitor

Start a background subagent that runs `make up && make logs` to capture live container output. Use the Task tool with `run_in_background: true` and `subagent_type: "Bash"` to run:

```bash
docker compose up --build -d 2>&1 && docker compose logs -f --tail=100 2>&1
```

### Step 2: Check for errors

Read the background task output periodically. Look for:

- **Elixir/Erlang crashes**: `** (EXIT)`, `** (RuntimeError)`, `** (FunctionClauseError)`, `CRASH REPORT`
- **Phoenix errors**: `[error]`, `(Phoenix.Router.NoRouteError)`, `(Plug.Conn.AlreadySentError)`
- **Ecto/DB errors**: `(Postgrex.Error)`, `(Ecto.ConstraintError)`, migration failures
- **Startup failures**: `exited with status`, `restart loop`, container exit codes
- **Compilation errors**: `== Compilation error`, `undefined function`, `module not found`
- **Asset build errors**: `esbuild`, `tailwind`, bundle failures

### Step 3: Debug — diagnose before fixing

When an error is found:

1. **Log the observation:**
   ```bash
   deciduous add observation "Error detected: <brief description>" -c 50
   ```

2. **Parse the error** — extract the exception type, message, and full stacktrace

3. **Read the crash site** — open the file at the top of the stacktrace. Read the FULL function body, not just the error line. Read the `@spec` and `@type` definitions for that function.

4. **Trace the call chain** — for each frame in the stacktrace (working down from crash site to entry point):
   - Read the calling function at that file:line
   - Identify what arguments it passed to the next function
   - Check if the data could have been nil, wrong type, wrong shape, or missing a key
   - Check pattern match clauses — does the function handle this input shape?

5. **Check types and contracts** — read `@type`, `@spec`, and `defstruct` for every module involved:
   - Does the caller's output type match the callee's input type?
   - Is there a struct field that could be `nil` but the code assumes it's always present?
   - Did a pattern match miss a clause?

6. **Identify the root cause** — the earliest point in the call chain where the fix should go. This is usually NOT the crash site (the symptom), but 1-3 frames down where the data shape diverged from what the code expected.

   ```
   ROOT CAUSE: <one sentence>
   WHERE: <file:line>
   WHY: <the data flow that leads here>
   ```

### Step 4: Write a Failing Test (RED)

**Before touching any source code**, write a test that reproduces the exact failure:

1. **Find the right test file** — mirror the source path. `lib/my_app/game/board.ex` → `test/my_app/game/board_test.exs`. Read the existing test file to match conventions.

2. **Write a focused test** that constructs the exact input data from the stacktrace, calls the function at the root cause, and asserts the correct behavior. Use a descriptive name: `"place_piece/2 handles piece without color field"`.

3. **Run it and confirm it fails:**
   ```bash
   mix test test/my_app/game/board_test.exs --only line:<line_number>
   ```
   If the test passes, the reproduction is wrong — rewrite it.

### Step 5: Fix at Root Cause (GREEN)

1. **Log the action:**
   ```bash
   deciduous add action "Fix: <what and why — root cause, not symptom>" -c 75 -f "file1.ex,file2.ex,test_file_test.exs"
   deciduous link <observation_id> <action_id> -r "Fixing detected error"
   ```

2. Make the **minimal source change** that makes the failing test pass. Apply the fix at the root cause location:
   - **Code bugs**: Edit the source file at the divergence point, not the crash site
   - **Missing migrations**: Run `mix ecto.gen.migration` and write the migration
   - **Config issues**: Fix the config file
   - **Dependency issues**: Update mix.exs and run `mix deps.get`

3. **Run the failing test again** — it must pass now. If it doesn't, the fix is wrong.

4. **Check for regressions** — grep for other callers of the changed function. Will this fix break them?

Do NOT create branches, stage files, or commit. Only modify files.

### Step 6: Verify Full Suite

After fixing:

1. Run `mix compile --warnings-as-errors && mix test` — all tests must pass (new and existing)
2. If `docker compose watch` is running, the fix will sync automatically. If not, rebuild: `docker compose up --build -d`
3. Tail the logs again to verify the error is resolved: `docker compose logs -f --tail=50`

### Step 7: Log outcome and report

1. **Log the outcome:**
   ```bash
   # If fixed:
   deciduous add outcome "Fixed: <root cause and resolution>. Test added." -c 95
   deciduous link <action_id> <outcome_id> -r "Fix verified"

   # If still broken:
   deciduous add outcome "Fix attempt failed: <why>" -c 30
   deciduous link <action_id> <outcome_id> -r "Fix did not resolve"
   ```

2. Summarize what happened:
   - What error was detected (the symptom)
   - What the root cause was (where the data diverged)
   - What test was written to reproduce it
   - What files were changed and why
   - Whether the fix resolved the issue

If the error persists after the fix, go back to Step 3 and debug again with the new information. Maximum 3 fix attempts before asking the user for help.

$ARGUMENTS