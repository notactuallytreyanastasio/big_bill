---
description: Debug an error from stacktrace and file context — write a failing test, then fix via TDD
allowed-tools: Bash(mix:*, elixir:*, cat:*), Read, Glob, Grep
argument-hint: <stacktrace or error message>
---

# Debug

**Diagnose, write a failing test, then fix.** This command takes an error (stacktrace, compilation error, or runtime exception), traces it to root cause, writes a test that reproduces the failure, then fixes the source to make it pass.

## Input

`$ARGUMENTS` is one of:
- A pasted stacktrace
- An error message from logs or compilation output
- A file:line reference with a description of the problem

## Step 1: Parse the Error

Extract from the stacktrace or error message:

1. **Error type** — the exception module (`ArgumentError`, `FunctionClauseError`, `KeyError`, `UndefinedFunctionError`, `CompileError`, etc.)
2. **Error message** — the human-readable description
3. **Origin** — the file and line where the error was raised (top of the stacktrace)
4. **Call chain** — every file:line in the stacktrace, from top (crash site) to bottom (entry point)

If the input is vague, say what's missing and ask for the full stacktrace.

## Step 2: Read the Crash Site

Read the file at the top of the stacktrace. Focus on:

- The exact line that raised the error
- The function it's in — read the full function body
- The `@spec` and `@type` definitions for that function (scroll up if needed)
- The struct or data shape being operated on

**Do not skim.** Read enough context to understand what data flows into the crash site.

## Step 3: Trace the Call Chain

For each caller in the stacktrace (working down):

1. Read the calling function at that file:line
2. Identify what arguments it passed to the next function
3. Check if the data could have been nil, wrong type, wrong shape, or missing a key
4. Check pattern match clauses — does the function handle this input shape?

Stop when you find the **divergence point** — where the actual data shape diverged from what the code expected. This is usually NOT the crash site itself, but 1-3 frames down.

## Step 4: Check Types and Contracts

Read the `@type`, `@spec`, and `defstruct` definitions for every module involved. Ask:

- Does the caller's output type match the callee's input type?
- Is there a struct field that could be `nil` but the code assumes it's always present?
- Did a pattern match miss a clause?
- Is a guard too narrow or too broad?

## Step 5: Identify Root Cause

State the root cause clearly:

```
ROOT CAUSE: <one sentence>
WHERE: <file:line>
WHY: <explain the data flow that leads to the crash>
```

The root cause is the earliest point where the fix should go — not the crash site (symptom) unless they're the same.

## Step 6: Write a Failing Test (RED)

**Before touching any source code**, write a test that reproduces the exact failure.

1. **Find the right test file** — follow the project's mirrored test structure. If the root cause is in `lib/my_app/game/board.ex`, the test goes in `test/my_app/game/board_test.exs`. If the file doesn't exist, create it.

2. **Read the existing test file** to understand conventions — what's aliased, how structs are built, how assertions are written. Match the style exactly.

3. **Write a focused test** that:
   - Constructs the exact input data that triggers the bug (the struct/args from the stacktrace)
   - Calls the function at the root cause location
   - Asserts the correct behavior (what SHOULD happen with this input)
   - Use a descriptive test name that explains the bug: `"place_piece/2 handles piece without color field"`

4. **Run the test and confirm it fails:**
   ```bash
   mix test test/my_app/game/board_test.exs --only line:<line_number>
   ```
   The test MUST fail. If it passes, your reproduction is wrong — the test doesn't capture the actual bug. Rewrite it.

### Test patterns by error type

| Error | Test approach |
|-------|--------------|
| `FunctionClauseError` | Call the function with the unmatched input, assert it returns a value instead of crashing |
| `KeyError` | Build the struct missing the key, call the function, assert correct behavior |
| `MatchError` | Pass the value that fails the match, assert the function handles it |
| `UndefinedFunctionError` | After fixing the typo/rename, test the correct function call |
| `Protocol.UndefinedError` | Pass nil or wrong type, assert the function guards against it |
| `CompileError` | Fix the syntax/reference, then write a test exercising the fixed code path |

## Step 7: Fix the Source (GREEN)

Now — and only now — edit the source code:

1. **What to change** — the specific file and function at the root cause
2. **The edit** — make the minimal change that makes the failing test pass
3. **Why this fixes it** — trace through the call chain to confirm the fix prevents the error
4. **What else it affects** — grep for other callers of the changed function to check for regressions

Run the test again:
```bash
mix test test/my_app/game/board_test.exs --only line:<line_number>
```

It MUST pass now. If it doesn't, your fix is wrong — not the test. Go back and re-examine the root cause.

## Step 8: Run Full Suite

```bash
mix compile --warnings-as-errors && mix test
```

All tests must pass — the new one AND all existing ones. If other tests break, your fix introduced a regression. Adjust the fix, not the other tests.

If the user passed `--fix` or asks you to fix it, apply everything. Otherwise, present the diagnosis and the test, and wait.

## Elixir-Specific Patterns

Common root causes to check for:

| Error | Likely cause |
|-------|-------------|
| `FunctionClauseError` | Missing pattern match clause, nil where value expected |
| `KeyError` | Accessing map key that doesn't exist, or using `map[:key]` on a struct |
| `UndefinedFunctionError` | Module not aliased, function renamed/removed, wrong arity |
| `ArgumentError` | Wrong type passed (e.g., string where atom expected) |
| `CompileError` | Syntax error, undefined variable, module cycle |
| `Protocol.UndefinedError` | Nil or wrong type passed to `Enum`, `String`, etc. |
| `BadMapError` | Calling map operations on nil |
| `MatchError` | Pattern match failed in `=` assignment |

$ARGUMENTS