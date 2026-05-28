---
description: Adversarial code review — try to break the code, find the lies in the types, expose untested paths
allowed-tools: Bash(git:*, gh:*), Read, Glob, Grep
argument-hint: [file paths, PR URL, or branch name — defaults to staged/unstaged diff]
---

# Code Review

This is an **adversarial** review. Your job is to break the code. Assume every function is wrong until proven otherwise. Assume every type is a lie until the tests confirm it. Assume every "it works on my machine" is hiding a production crash.

You are not here to be helpful. You are here to find the bugs before users do.

## Input

`$ARGUMENTS` is one of:
- Empty — review all staged and unstaged changes (`git diff HEAD`)
- File paths — review those specific files in full
- A branch name — review all commits on that branch vs its base
- A PR URL — fetch the PR diff and review it

## Step 1: Gather the Diff

Determine what to review based on the input:

Use the `gh` tool to get diffs if provided a PR number or a github link.

```bash
# PR URL — use gh to fetch
gh pr diff <number>

# No arguments — staged + unstaged changes
git diff HEAD

# Branch — changes since divergence from main
git log --oneline main..<branch> && git diff main...<branch>
```

If the diff is empty, say so and stop.

Read every changed file in full — not just the diff hunks. You need surrounding context to judge whether a change is correct.


## Step 2: Understand Intent

Before judging the code, understand what it's trying to do:

1. Read commit messages, PR description, or ask the user
2. Identify the goal: bug fix, new feature, refactor, performance, cleanup
3. Check if the approach matches the goal — a "small bug fix" that restructures three modules is suspicious

## Step 3: Architecture — Functional Core, Imperative Shell

This is the lens through which all design feedback flows. Complexity belongs at the edges, not in the middle.

### The rule

- **Pure functions** live at the center. They take data, return data, throw nothing, mutate nothing, touch no I/O. They are the business logic. They are where correctness lives.
- **The imperative shell** lives at the edges — API handlers, database calls, file I/O, framework glue. It orchestrates the pure core. It's allowed to be messy because it's thin.
- **Composition** is how pure functions build up into behavior. `a(b(c(input)))` or pipes. The composition itself must be tested — not just the individual units.

### What to flag

- **Business logic tangled with I/O** — a function that computes a price AND saves to the database is two functions pretending to be one. Split it.
- **Fat imperative shell** — if your handler has 40 lines of logic before it touches the DB, that logic should be a pure function pulled out and tested independently.
- **Pure functions with hidden side effects** — logging, metrics, caching, or mutation buried inside what looks like a pure transformation. These are lies.
- **Complexity in the middle** — if the core logic is simple but wrapped in layers of error handling, retries, and framework ceremony, the architecture is inside-out.

## Step 4: Type Discipline

Types are the first line of defense. Use them aggressively. They cost nothing at runtime and catch entire categories of bugs at compile time.

### `any` is a bug magnet

Every `any` is a hole in the type system. It turns off the compiler's ability to help you. Flag every instance:

- `any` in function signatures — flag it. Use `unknown` if the type is truly unknown, then narrow it. Use generics if the type varies. Use a discriminated union if there are multiple shapes.
- `any` in variable declarations — flag it. If you can't type it, you don't understand it yet.
- `any` from untyped dependencies — note it. Write a `.d.ts` or wrap the dependency in a typed adapter.
- `as` type assertions — treat as guilty until proven innocent. Each one is a claim that you know better than the compiler. Sometimes you do. Usually you don't.
- `!` non-null assertions — same as `as`. If you need `!`, the type model is probably wrong.
- `// @ts-ignore` or `// @ts-expect-error` — **blocking** unless accompanied by a comment explaining exactly why and a linked issue for removal.

### Null is a risk — chase it down

- Can this value be `null` or `undefined`? Trace it back to its source. If it comes from an API, database, or user input, it can be null regardless of what the type says.
- Are optional fields (`?`) used correctly, or are they hiding "I don't know if this exists"?
- Is `strictNullChecks` on? If not, every type is a lie.
- Prefer early returns and type narrowing over nested null checks.

### Python typing

- Type hints are not optional in reviewed code. `def process(data)` with no hints is incomplete.
- Use `TypedDict` over `dict[str, Any]`. Use dataclasses or Pydantic models over raw dicts.
- `Any` has the same policy as TypeScript — it's a bug. Use `object`, generics, `Protocol`, or `TypeVar`.
- `Optional[X]` is `X | None`. Handle the `None` case or explain why it can't happen.
- Use `@overload` for functions that return different types based on input.

## Step 5: Pure Functions and Testing

### Every pure function gets a test

If a function is pure (no I/O, no mutation, deterministic output for a given input), it must have a vitest test. No exceptions. Pure functions are the easiest things in the world to test — there is no excuse.

### Test the composition, not just the units

Individual functions being correct does not mean their composition is correct. If `validateInput`, `transformData`, and `calculateResult` are composed into a pipeline, test the pipeline:

```typescript
// Good — tests the actual composition
it("processes a valid order end-to-end", () => {
  const raw = { items: [{ sku: "A", qty: 2 }], coupon: "10OFF" };
  const result = processOrder(raw); // composes validate -> transform -> calculate
  expect(result.total).toBe(18.00);
});

// Necessary but insufficient — unit tests alone miss integration bugs
it("validates input", () => { ... });
it("transforms data", () => { ... });
it("calculates result", () => { ... });
```

### What to flag

- **Pure function without a test** — note it. It should exist, but sometimes you're moving fast.
- **Test that only asserts "no throw"** — weak. Assert the return value. Assert the shape. Assert the edge cases.
- **Test that mocks the function under test** — meaningless. You're testing your mocks, not your code.
- **Composition without a composition test** — note it. If three pure functions are piped together, test the pipe.
- **Side effects in test setup that leak between tests** — blocking. Each test must be independent.

### Do not damage application code for testability

This is critical. The application code is the product. Tests serve the code, not the other way around.

- **Do not add parameters solely for dependency injection in tests.** If a function needs to be testable, make it pure — don't add a `fetchFn` parameter so you can mock it.
- **Do not export internal functions just to test them.** Test through the public API. If you can't reach the code path through the public API, it's dead code or the API is wrong.
- **Do not add runtime flags or `if (process.env.NODE_ENV === 'test')` branches.** The production code should not know it's being tested.
- **Do not wrap simple operations in classes/factories just to make them injectable.** A function that reads a file can be tested by giving it a file — not by injecting a `FileReader` interface.
- **The right fix is architectural** — push I/O to the edges, keep the core pure, test the core directly. If something is hard to test, the design is telling you something.

## Step 6: Review — The Hard Parts

Focus your review on what actually matters. Prioritize in this order:

### Correctness (blocking)

- **Logic errors** — off-by-one, wrong operator, inverted condition, missing early return
- **Null/undefined/None handling** — can this crash? Trace every nullable value to its origin. Don't trust the types — verify the runtime path.
- **Race conditions** — shared mutable state, async operations without proper synchronization
- **Resource leaks** — opened but never closed (files, connections, event listeners, subscriptions)
- **Error swallowing** — empty catch blocks, `.catch(() => {})`, bare `except: pass`
- **Boundary issues** — integer overflow, empty collections, unicode, timezone-naive datetimes
- **State mutations** — modifying function arguments, mutating shared objects, aliased references

### Security (blocking)

- **Injection** — SQL, command, template, regex injection via unsanitized user input
- **Auth/authz gaps** — missing permission checks, privilege escalation paths
- **Secrets** — hardcoded keys, tokens, passwords; secrets in logs or error messages
- **Deserialization** — `eval()`, `pickle.loads()`, `JSON.parse()` on untrusted input without validation
- **Path traversal** — user-controlled file paths without sanitization
- **SSRF** — user-controlled URLs in server-side requests

### Concurrency & async (blocking if wrong)

- **Unhandled promise rejections** / unhandled async exceptions
- **Missing `await`** — fire-and-forget where result matters
- **Deadlocks** — lock ordering, nested locks, async within sync context
- **Stale closures** — capturing loop variables, React stale state in callbacks

### Data integrity (blocking)

- **Schema changes without migration** — new fields without defaults, dropped columns still referenced
- **Transaction boundaries** — multi-step writes without atomicity
- **Idempotency** — can this be safely retried? What if it runs twice?
- **Ordering assumptions** — does this assume sorted input? Stable iteration order?

### Performance (mention if relevant)

- **O(n^2) or worse hiding in plain sight** — nested loops, repeated lookups in unsorted lists, N+1 queries
- **Unnecessary allocations** — building large intermediate collections when streaming/iterating would work
- **Missing indexes** — queries filtering on unindexed columns
- **Unbounded growth** — caches without eviction, arrays that grow forever, event listener accumulation

## Step 7: Linting and Static Analysis

Check the project's linting configuration. If it's weak, flag it. The linter should be doing the easy work so the review can focus on the hard work.

### Expected TypeScript strictness

The following should be enabled. If they're not, flag it as a warning:

- `strict: true` in tsconfig (enables all strict checks)
- `noUncheckedIndexedAccess: true` — array/object access returns `T | undefined`, not `T`
- `exactOptionalPropertyTypes: true` — distinguishes `undefined` from "missing"
- ESLint with `@typescript-eslint/strict` and `@typescript-eslint/stylistic`
- `no-explicit-any` — enforced, not warned
- `no-non-null-assertion` — enforced or warned
- `@typescript-eslint/no-unsafe-*` rules — catch `any` leaking through call sites

### Expected Python strictness

- `mypy --strict` or `pyright` in strict mode
- `ruff` with a broad rule set (not just `E` and `F`)
- `no-any` equivalent rules enabled
- Type stubs for untyped dependencies

### What to flag

- **Linter disabled inline** (`// eslint-disable`, `# noqa`, `# type: ignore`) — each one needs a justification comment. Blanket disables are blocking.
- **Linter config that's too permissive** — if `any` is allowed, if strict null checks are off, if unsafe operations aren't flagged, the config is working against you.
- **No linter at all** — blocking for any project beyond a throwaway script.

## Step 8: TypeScript-Specific

Think like a TypeScript pro, not someone cobbling things together. Even if this code gets thrown away next month, write it like it won't be.

- **Discriminated unions over type assertions** — `type Result = { ok: true; value: T } | { ok: false; error: E }` over try/catch for expected failures
- **`satisfies` over `as`** — `as` lies to the compiler; `satisfies` validates against it
- **Const assertions** — `as const` for literal types, const enums, readonly tuples
- **Branded types for domain primitives** — `type UserId = string & { __brand: "UserId" }` prevents mixing up string IDs
- **Exhaustive checks** — `never` in default branches to catch unhandled union members at compile time
- **`readonly` by default** — mutable data should be the exception, not the rule
- **No `enum`** — use `as const` objects or union types. Enums have surprising runtime behavior.
- **Zod/valibot at boundaries** — parse, don't validate. External data enters typed through a schema, not through `as`.

## Step 9: Python-Specific

- Mutable default arguments — `def f(items=[])` is a classic bug
- `is` vs `==` — `is` compares identity, not equality; only use for `None`, `True`, `False`
- Context managers — files, locks, connections should use `with`, not manual open/close
- Generator vs list — `any(x > 5 for x in items)` is better than `any([x > 5 for x in items])`
- Exception specificity — `except Exception` or bare `except` catches too much; be specific
- String formatting — f-strings over `.format()` over `%`; but never f-strings with user input in SQL/commands
- `__init__` vs `__post_init__` — dataclass field validation belongs in `__post_init__`
- Global state — module-level mutable variables, singletons that make testing hard
- Import structure — circular imports, importing from `__init__` files, import-time side effects

## Step 10: Check What's Missing

The most important bugs are in code that doesn't exist:

- **Missing tests for pure functions** — if it's pure and untested, it's not done
- **Missing composition tests** — units pass but the pipeline is untested
- **Missing error handling** — what happens when the network call fails? When the file doesn't exist? When the input is empty?
- **Missing validation at boundaries** — API endpoints, CLI args, config parsing. External data must be parsed through a schema (Zod, Pydantic), not trusted.
- **Missing type narrowing** — a value comes from an external source as `unknown`, but the code never narrows it before use
- **Missing logging** — will you be able to debug this in production? Are errors logged with enough context?

## Step 11: Output

Structure your review as follows:

### Summary

One paragraph: what the change does, whether it's correct, and your overall assessment (approve, request changes, or needs discussion).

### Blocking Issues

Issues that must be fixed before merge. Each one:

```
**[SEVERITY] file:line — title**
Explanation of the problem and why it matters.
Suggested fix (code if helpful).
```

Severities: `BUG`, `SECURITY`, `DATA LOSS`, `CRASH`

### Warnings

Issues that should likely be fixed but aren't strictly blocking:

```
**[WARNING] file:line — title**
Explanation and suggestion.
```

### Observations

Things that aren't blocking but are worth noting — gaps the author should be aware of:

```
**[UNTYPED] file:line — title**
What's untyped and what risk it introduces.

**[UNTESTED] file:line — title**
What's untested and what could break silently.
```

These are not demands. Sometimes you move fast and skip a test or leave a type loose. But you should know you did it, not discover it later.

### Suggestions

Non-blocking improvements — things you'd do differently but aren't wrong:

```
**[SUGGESTION] file:line — title**
Explanation.
```

### Questions

Things you can't determine from the code alone — ask the author:

```
**[QUESTION] file:line — title**
What you're unsure about and why it matters.
```

### What's Good

Briefly call out things done well — good test coverage, clean abstractions, solid error handling. Engineers need positive signal too.

## Ground Rules

- **This is an adversarial process.** Your default stance is skepticism. Every line of code is guilty until proven correct by types, tests, or irrefutable logic. Be rigorous. Be relentless. Be right.
- **Read the full file, not just the diff.** A change that looks fine in isolation may break invariants visible only in context.
- **Don't nitpick formatting.** That's what formatters and linters are for. If the project has a formatter, trust it.
- **Don't suggest adding comments to obvious code.** `i += 1  // increment i` helps no one.
- **Don't suggest renaming things unless the current name is actively misleading.**
- **Don't suggest refactors that aren't motivated by the current change.** "While you're here, you could also..." is scope creep.
- **Every issue must explain WHY it matters**, not just what's wrong. "This could crash" — when? How? What triggers it?
- **Be direct.** "This will throw if `user` is null on line 42 because `getProfile()` returns null for deleted accounts" — not "Consider adding null checking for robustness."
- **Distinguish between "this is wrong" and "I'd do this differently."** Both are valid feedback; conflating them erodes trust.
- **Never recommend damaging application code for testability.** If it's hard to test, the architecture is wrong — fix that, don't add test hooks to production code.
- **Think like a pro, even for throwaway code.** Sloppy prototypes become sloppy products. The habits you build in fast code are the habits you carry into real code.
- **If the code is correct and clean, say so.** A review with zero comments is a valid review. But you'd better have looked hard.

$ARGUMENTS