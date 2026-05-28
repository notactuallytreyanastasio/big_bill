Systematically improve Elixir code quality across the project. These are often quick builds and one-offs — this skill enforces discipline where speed would otherwise erode it.

## Ground Rules

- Always create a branch for improvements and open a pull request.
- Eliminate every compiler warning. The compiler tells you how to fix it — follow its lead.
- Install Credo if it isn't present. Run it in strict mode. Follow every rule, no exceptions.
- Write pure functions that are easy to test.
- Add tests for every major public API function.
- Structure code as a functional core with an imperative shell.
- Find dead code and remove it.
- Always remove inline CSS.
- Write the test first — strict TDD. Test composition of functions, not just individual units.
- Test coverage starts from zero, so begin simply. Integration tests first for the messy parts, then unit tests as the code improves.

---

## Elixir Language

### Pattern Matching
- Prefer pattern matching over conditionals. Match on function heads instead of `if`/`case` in the body.
- `%{}` matches any map, not just empty ones. Use `map_size(map) == 0` to check for empty.

### Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for fallible operations.
- Don't raise exceptions for control flow.
- Use `with` for chaining ok/error tuples.

### Function Design
- Use guards: `when is_binary(name) and byte_size(name) > 0`.
- Prefer multiple function clauses over complex conditionals.
- Name functions clearly: `calculate_total_price/2`, not `calc/2`.
- Predicates end with `?`, don't start with `is_`. Reserve `is_` for guards.

### Data Structures
- Use structs when the shape is known: `defstruct [:name, :age]`.
- Use keyword lists for options: `[timeout: 5000, retries: 3]`.
- Use maps for dynamic key-value data.
- Prepend to lists: `[new | list]`, not `list ++ [new]`.

### Things That Will Bite You
- No `return` statement, no early returns. The last expression is always the return value.
- Lists do not support bracket access. Use `Enum.at/2`, pattern matching, or `List` functions.
- Variables are immutable but rebindable. Block expressions must bind their result:

      # Wrong — rebinding inside the block is lost
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # Right — bind the block's result
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- Never nest multiple modules in the same file — it causes cyclic dependencies.
- Never use map access syntax (`changeset[:field]`) on structs. Use dot access (`my_struct.field`) or APIs like `Ecto.Changeset.get_field/2`.
- Don't use `String.to_atom/1` on user input — atoms are never garbage collected.
- Don't use `Enum` on large collections when `Stream` is appropriate.
- Don't nest `case` statements — refactor to `with` or separate functions.
- Prefer `Enum.reduce` over manual recursion. When recursion is necessary, use pattern matching in function heads for the base case.
- The process dictionary is a code smell.
- Only use macros if explicitly asked.
- The standard library is rich — use it.
- Elixir's standard library handles dates and times. Use `Time`, `Date`, `DateTime`, and `Calendar`. Only add `date_time_parser` for parsing, and only if asked.
- OTP primitives like `DynamicSupervisor` and `Registry` require names in their child spec: `{DynamicSupervisor, name: MyApp.MyDynamicSup}`.
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure. Almost always pass `timeout: :infinity`.

---

## Code Style

### Aliases

Each module gets its own alias line. No compound aliases. Alphabetical order, always.

```elixir
# Wrong — compound alias
alias Optimizer.Ecto.{Customer, Repo}

# Right — one per line, sorted
alias Optimizer.Ecto.Customer
alias Optimizer.Ecto.Repo
```

### Pipe Chains Start with Data

Begin pipe chains with the raw value, not a function call. Data flows left to right.

```elixir
# Wrong — starts with function call
Enum.take(list, 5) |> Enum.shuffle() |> pick_winner()

# Right — starts with data
list |> Enum.take(5) |> Enum.shuffle() |> pick_winner()
```

Exception: when starting with a function call genuinely reads better for complex logic.

### Don't Duplicate `attr` Defaults with `assign_new`

When an `attr` declares a `default`, that default is already guaranteed. Adding `assign_new` for the same key is redundant.

```elixir
# Wrong — redundant assign_new
attr :warnings, :list, default: [], doc: "List of warning messages"
def warning_list(assigns) do
  assigns = assign_new(assigns, :warnings, fn -> [] end)
  # ...
end

# Right — trust the attr default
attr :warnings, :list, default: [], doc: "List of warning messages"
def warning_list(assigns) do
  # ...
end
```

`assign_new/3` is appropriate only when:
- You need to lazily compute a value not covered by an `attr` default.
- The attribute has no default declared.
- You need to derive a value from other assigns.

### Don't Add Defensive Formatting for Known Types

If the type is known and guaranteed, don't wrap it in safety checks. Trust the data contract.

### One Source of Truth for Logic

Never duplicate validation, transformation, or business logic across functions. Duplicates drift apart and breed bugs.

### Update Call Sites, Don't Add Compatibility Shims

When changing a function signature, update every call site. Don't leave behind deprecated wrapper functions. One signature. Zero compatibility layers.

---

## Phoenix

### Router

- `scope` blocks include an optional alias that prefixes all routes within. Be mindful of this to avoid duplicate module prefixes.
- You never need your own `alias` in routes — the scope provides it.
- `Phoenix.View` no longer exists. Don't use it.

### LiveView

- Never use `live_redirect` or `live_patch` (deprecated). Use `<.link navigate={href}>`, `<.link patch={href}>`, `push_navigate`, and `push_patch`.
- Avoid LiveComponents unless you have a strong reason.
- Name LiveViews with a `Live` suffix: `AppWeb.WeatherLive`.

### Streams

Always use streams for collections. Never assign raw lists — they balloon memory.

### Forms

Always use `to_form/2` and `<.form for={@form}>`. Never pass changesets directly to templates.

---

## Testing

- Never mock Ecto repositories. Use the actual test database.
- Use `start_supervised!/1` to start processes.
- Never use `Process.sleep/1` or `Process.alive?/1` in tests.
- Use `Phoenix.LiveViewTest` and `LazyHTML` for LiveView assertions.
- Test outcomes, not implementation details.

---

## Mix

- Read docs before using tasks: `mix help task_name`.
- Debug test failures: `mix test test/my_test.exs` or `mix test --failed`.
- `mix deps.clean --all` is almost never what you want. Avoid it.

$ARGUMENTS