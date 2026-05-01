# Code Standards

The conventions below are extracted from `RULES.md`, `.credo.exs`, the project's existing module shapes, and the dialyzer flags. `RULES.md` and `CLAUDE.md` are the authoritative sources for process rules; this document focuses on the **code-level** conventions a contributor needs.

## Workflow rules (project-wide)

Full text in `RULES.md`. Key rules contributors must follow:

1. **Establish understanding before acting.** Read the relevant files and `RULES.md` before making changes.
2. **Behaviour spec before implementation.** Specs come first; implementation makes them pass. Mechanical fixes (typos, comments) are exempt.
3. **Coding task template before code.** Every new or modified function gets a documented purpose, public interface, inputs, outputs, and contract before code is written. If a spec exists and the implementation has drifted, update the spec first.
4. **Tests before implementation.** TDD is mandatory.
5. **Investigate before fixing.** Form a hypothesis; gather evidence; only then edit.
6. **Verify before declaring done.** Run the tests at the narrowest useful scope, then widen if the change has cross-cutting reach.
7. **Delegate code changes to `claude-copilot:code-implementer`.** All Elixir source edits go through that subagent. Configuration and documentation changes are exempt.
8. **Layer test execution narrow → broad.** Single test by line → file → app → project. Don't run the whole suite for a one-line change.
9. **Run quality checks after every code change.** Tests first, then style, then types. See `testing-guide.md` for commands.

## Module conventions

### Module documentation

- Every public module has a `@moduledoc` written from the **caller's** point of view: what it's for, when to use it, and what shapes it accepts and returns.
- Internal modules use `@moduledoc false` and a short comment block explaining their role. Examples: `ElixirExec.Options`, `ElixirExec.Runner`, `ElixirExec.Stream`, `ElixirExec.StreamSupervisor`, `ElixirExec.Stream.Buffer`.
- `BlitzCredoChecks.DocsBeforeSpecs` is enabled — `@doc` must precede `@spec` for every public function.

### Function documentation

Every public function carries a `@doc` block with this structure:

```elixir
@doc """
One-line summary that names the action.

## Parameters

  - `name` - `type`. Description.

## Returns

`shape_a` when condition_a.
`shape_b` when condition_b.
`{:error, term()}` when ...

## Examples

    iex> ...
"""
@spec function(types) :: return_type
def function(...), do: ...
```

`lib/elixir_exec.ex` is the canonical reference — every public function in that module follows this template. Doctests are used wherever the example doesn't need a side-effecting setup; `BlitzCredoChecks.DoctestIndent` enforces consistent indentation.

### Specs

- Every public function carries an `@spec`.
- `@type` declarations live near the top of the module — see the type block in `lib/elixir_exec.ex` for the canonical placement.
- Dialyzer runs with `:unmatched_returns` and `:no_improper_lists` flags. `.dialyzer-ignore.exs` is empty — keep it that way.

## Code style

### Equality

- **Always use strict equality (`===` / `!==`).** `BlitzCredoChecks.StrictComparison` enforces this.
- Pattern matching is preferred where it expresses intent more clearly than a comparison.

### Boolean and predicate functions

- Predicate function names end in `?` (e.g. `exhausted?/1`). Enforced by `Credo.Check.Readability.PredicateFunctionNames`.
- `BlitzCredoChecks.NoIsBitstring` — use `is_binary/1`, never `is_bitstring/1`.

### Async tests

- `async: true` is the default for unit tests. `BlitzCredoChecks.NoAsyncFalse` flags the **explicit** `async: false`. The check is informational — integration tests that spawn real OS processes legitimately need `async: false`, and that's used in `elixir_exec_test.exs` and `runner_test.exs`. Use `async: false` only when you have an explicit reason; document it.

### Imports

- `BlitzCredoChecks.ImproperImport` is configured to allow only `ExUnit`, `ExUnit.CaptureLog`, and `Mix`. Other imports are rejected — alias instead.

### Line length

- Max 120 characters per line (`Credo.Check.Readability.MaxLineLength`).

### Whitespace and ordering

- `Credo.Check.Readability.AliasOrder` — alias declarations are sorted alphabetically.
- `Credo.Check.Readability.TrailingBlankLine`, `TrailingWhiteSpace`, `RedundantBlankLines` — enforced.
- `Credo.Check.Consistency.SpaceAroundOperators`, `SpaceInParentheses`, `LineEndings`, `TabsOrSpaces`, `ParameterPatternMatching` — enforced.

### Test naming

- Test names start lowercase. `BlitzCredoChecks.LowercaseTestNames` enforces this.

### DSL parentheses

- `BlitzCredoChecks.NoDSLParentheses` flags parentheses on DSL-style calls (e.g. `defmacro` invocations) that conventionally omit them.

### Numbers

- Large numeric literals use `_` separators (e.g. `5_000`, `120_000`). `Credo.Check.Readability.LargeNumbers` enforces this.

## Project structure conventions

- Public API lives in `lib/elixir_exec.ex` only. Other modules are internal unless their structs appear in return types (`OSProcess`, `Output`).
- Internal modules go in `lib/elixir_exec/`. Sub-namespaces (e.g. the `Stream.Buffer` data type) go in `lib/elixir_exec/stream/`.
- Test files mirror `lib/` exactly: `lib/elixir_exec/runner.ex` ↔ `test/elixir_exec/runner_test.exs`.
- The top-level public-API test file is `test/elixir_exec_test.exs` and uses `doctest ElixirExec`.

## Errors and return shapes

- Public functions return `{:ok, value} | {:error, reason}` or `:ok | {:error, reason}` for actions. Never raise from a public function for an expected failure.
- Validation errors propagate as `{:error, %NimbleOptions.ValidationError{}}`.
- Cross-key validation errors use `{:error, {:illegal_combination, atom}}`.
- `:erlexec` rejection paths surface as `{:error, term()}` unchanged.
- `await_exit/2` and `stop_and_wait/2` follow `:erlexec`'s native shapes — not every function returns `{:ok, _}`. See the API reference for each.

## Credo and Dialyzer

The Credo config is `strict: true` with the full readability/refactor/warning suite, plus the BlitzCredoChecks pack. Run before commits:

```sh
mix credo --strict
mix dialyzer
```

Dialyzer's PLT is cached in `dialyzer/` (committed) so first runs are fast. If types change such that a PLT rebuild is needed, regenerate with `mix dialyzer --plt`.

## See also

- `RULES.md` — full workflow rules.
- `CLAUDE.md` — Claude-Code-specific entry pointer.
- [`testing-guide.md`](testing-guide.md) — test patterns.
- `.credo.exs` — full check list.
