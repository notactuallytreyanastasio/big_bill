# Background Monitor

Launch the dev server, file watcher, and error listener as background subagents so the main session stays free for work.

## Instructions

### Step 1: Start the containers

Use the **Bash tool** with `run_in_background: true`:

```bash
docker compose up --build -d 2>&1
```

Wait for it to complete. Verify the containers are healthy:

```bash
docker compose ps
```

### Step 2: Start the file watcher

Use the **Bash tool** with `run_in_background: true`:

```bash
docker compose watch 2>&1
```

This is **required for hot reload**. On macOS, Docker volume mounts don't propagate inotify events. `docker compose watch` syncs files into the container and triggers proper filesystem events that Phoenix live reload detects. Without it, code and CSS changes won't reflect in the browser.

### Step 3: Start the log stream

Use the **Bash tool** with `run_in_background: true`:

```bash
docker compose logs -f --tail=0 2>&1
```

Save the task ID and output file path — the listener subagent will poll this.

### Step 4: Spawn the listener subagent

Use the **Task tool** with `subagent_type: "general-purpose"` and `run_in_background: true` to launch a long-running agent with this prompt:

> You are a continuous error listener for a Phoenix/Elixir Docker app.
>
> Your job is to poll the log output file at `<output_file>` every 10 seconds using the Read tool (read the last 100 lines). On each poll:
>
> 1. **Scan for error patterns:**
>    - `[error]` — Elixir Logger errors
>    - `** (` — Elixir exceptions (RuntimeError, FunctionClauseError, etc.)
>    - `CRASH REPORT` — OTP crash reports
>    - `exited with` — process/container exit
>    - `(Postgrex.Error)` — database errors
>    - `(Ecto.` — Ecto errors
>    - `== Compilation error` — compile failures
>    - `FATAL` — Postgres fatal errors
>    - `502` / `503` — service unavailable
>
> 2. **Ignore noise:** `[info]`, `[debug]`, healthcheck pings, normal request logs
>
> 3. **On error detection — classify severity:**
>    - **Critical** (app down): crashes, FATAL DB errors, container exits
>    - **Error** (degraded): runtime errors, failed requests
>    - **Warning**: one-off errors — wait for 3 occurrences in 60s before acting
>
> 4. **For Critical/Error — TDD healing cycle:**
>
>    **Phase 1: Observe**
>    a. Log observation: `deciduous add observation "Listener detected: <error summary>" -c 50`
>
>    **Phase 2: Debug (diagnose before fixing)**
>    b. Parse the error — extract the exception type, message, and full stacktrace
>    c. Read the crash site — the file:line at the top of the stacktrace. Read the FULL function body, not just the line
>    d. Trace the call chain — for each caller in the stacktrace, read the calling function. Identify what arguments were passed and where the data shape diverged from what the code expected
>    e. Check types and contracts — read `@type`, `@spec`, and `defstruct` for every module involved. Does the caller's output match the callee's input?
>    f. Identify the root cause — the earliest point where the fix should go, which is often NOT the crash site
>
>    **Phase 3: Write a Failing Test (RED)**
>    g. Find the test file that mirrors the source path (e.g., `lib/my_app/game/board.ex` → `test/my_app/game/board_test.exs`). Read it to match conventions
>    h. Write a test that constructs the exact input from the stacktrace, calls the root cause function, and asserts correct behavior
>    i. Run the test and confirm it FAILS: `mix test <test_file> --only line:<N>`
>    j. If it passes, the reproduction is wrong — rewrite the test
>
>    **Phase 4: Fix the Source (GREEN)**
>    k. Log the action: `deciduous add action "Auto-heal: <what and why>. Test added." -c 75 -f "file1.ex,test_file_test.exs"` and link to the observation
>    l. Make the minimal source change that makes the failing test pass
>    m. Run the new test again — it must pass now
>    n. Run full suite: `mix compile --warnings-as-errors && mix test`
>    o. No need to rebuild — `docker compose watch` will sync the fix automatically
>    p. Watch logs for 15 seconds to verify the error is gone
>
>    **Phase 5: Record**
>    q. Log outcome: `deciduous add outcome "Auto-healed: <summary>. Regression test added." -c 95` (or `"Auto-heal failed: <why>" -c 30`) and link to the action
>
> 5. **Rules:**
>    - **Test before fixing** — never edit source without a failing test that reproduces the bug
>    - **Debug before testing** — never write a test without tracing the call chain first
>    - Never fix the same error more than twice — print `LISTENER: Could not auto-heal "<error>". Manual intervention needed.`
>    - Never weaken or delete existing tests to make them pass
>    - Never delete or weaken error handling
>    - Always run full suite (`mix compile --warnings-as-errors && mix test`) after the fix
>    - Do NOT create branches, stage files, or commit. Only modify files.
>    - Log every observation, action, and outcome to deciduous
>
> 6. **Loop forever** — after handling an error (or finding none), sleep 10 seconds and poll again.

Pass the actual output file path from Step 3 into the prompt where `<output_file>` appears.

### Step 5: Confirm to the user

Tell the user:
- Containers are up (show `docker compose ps` output)
- File watcher is syncing (hot reload active)
- Log listener is monitoring for errors
- Provide task IDs so they can check output files
- They can continue working normally in this session

### Step 6: Periodic check-in (optional)

If the user asks about monitor status, read the subagent output files and summarize:
- Whether containers, watcher, and listener are still running
- Any errors detected and actions taken
- Current log activity level

$ARGUMENTS