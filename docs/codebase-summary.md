# Codebase Summary

## Layout

```
elixir_exec/
├── lib/
│   ├── elixir_exec.ex                  Public API surface (the only module callers should touch).
│   └── elixir_exec/
│       ├── application.ex              OTP application — starts ElixirExec.StreamSupervisor.
│       ├── options.ex                  NimbleOptions schemas + Elixir→Erlang option translation.
│       ├── os_process.ex               %ElixirExec.Stream{} struct + decode_reason/1.
│       ├── output.ex                   %ElixirExec.Output{} struct + from_proplist/1.
│       ├── runner.ex                   Validate → swap_stream → :exec.run/run_link → finalize.
│       ├── stream.ex                   GenServer worker that turns erlexec messages into an Enumerable.
│       ├── stream/buffer.ex            Pure data structure backing the streaming worker.
│       └── stream_supervisor.ex        DynamicSupervisor for Stream workers (:temporary restart).
├── test/                               Mirrors lib/ layout. ExUnit + doctests.
├── dialyzer/                           Local PLT cache (gitignored content; cache files are committed).
├── mix.exs                             Project, deps, package, dialyzer, ExDoc, coveralls config.
├── mix.lock                            Pinned versions.
├── .credo.exs                          Strict Credo + BlitzCredoChecks rules.
├── .dialyzer-ignore.exs                Empty — no warnings suppressed.
├── .formatter.exs                      Formatter inputs for {mix,.formatter}.exs and {config,lib,test}/**.
├── coveralls.json                      ExCoveralls config (minimum_coverage: 0).
├── codecov.yml                         Codecov gates (project & patch target 10%).
├── .gitignore                          Standard Elixir + .claude/.
├── CLAUDE.md                           Pointer to RULES.md for Claude Code agents.
├── RULES.md                            Project-wide development rules.
└── README.md                           Project intro and quickstart.
```

## Source size

| File | Lines |
|---|---:|
| `lib/elixir_exec.ex` | 832 |
| `lib/elixir_exec/options.ex` | 294 |
| `lib/elixir_exec/stream/buffer.ex` | 298 |
| `lib/elixir_exec/stream.ex` | 217 |
| `lib/elixir_exec/runner.ex` | 148 |
| `lib/elixir_exec/stream_supervisor.ex` | 117 |
| `lib/elixir_exec/os_process.ex` | 92 |
| `lib/elixir_exec/output.ex` | 81 |
| `lib/elixir_exec/application.ex` | 14 |
| **Total `lib/`** | **2,093** |
| **Total `test/`** | **2,040** |

Test-to-source ratio is roughly 1:1 in line count, which reflects an intentionally thorough integration suite — almost every public function is exercised against a real OS process rather than a mock.

## Module roles

| Module | Role | Visibility |
|---|---|---|
| `ElixirExec` | Public API — the only module library callers should reference. | Public |
| `ElixirExec.Application` | OTP application callback. | Public (OTP needs to find it) but not user-facing. |
| `ElixirExec.Stream` | Struct returned from async runs. | Public — appears in return types. |
| `ElixirExec.Output` | Struct returned from sync runs. | Public — appears in return types. |
| `ElixirExec.Options` | Option schemas + Erlang translation. | Internal (`@moduledoc false`). |
| `ElixirExec.Core` | Implements `run/run_link` orchestration. | Internal. |
| `ElixirExec.StreamSupervisor` | DynamicSupervisor for stream workers. | Internal. |
| `ElixirExec.Stream` | GenServer that exposes erlexec output as an `Enumerable`. | Internal. |
| `ElixirExec.Stream.Buffer` | Pure data type backing `ElixirExec.Stream`. | Internal. |

## Key dependencies

### Runtime

| Package | Lock version | Purpose |
|---|---|---|
| `erlexec` | `~> 2.3` | Erlang port driver that does the actual fork/exec, signal delivery, stdin/stdout/stderr plumbing, pty allocation, and exit reporting. The whole library is a façade in front of this. |
| `nimble_options` | `~> 1.1` | Schema-based keyword-list validator. Powers `ElixirExec.Options.validate_command/1` and `validate_exec/1`. |

### Dev / Test only

| Package | Constraint | Purpose |
|---|---|---|
| `credo` | `~> 1.7` | Static code analysis. Configured `strict: true`. |
| `blitz_credo_checks` | `~> 0.1.5` | Custom Credo rules (`StrictComparison`, `NoAsyncFalse`, `DocsBeforeSpecs`, `DoctestIndent`, `LowercaseTestNames`, `NoIsBitstring`, `NoDSLParentheses`, `ImproperImport`). |
| `dialyxir` | `~> 1.4` | Mix wrapper for Dialyzer. PLTs cached in `dialyzer/`. |
| `excoveralls` | `~> 0.18` | Coverage tooling. `test_coverage: [tool: ExCoveralls]` is set in `mix.exs`. |
| `ex_doc` | `>= 0.0.0` | Generate HTML docs to `doc/` from `@moduledoc` and `@doc` content. |

For exact pinned versions, see `mix.lock`.

## Build / run / test commands

| Goal | Command |
|---|---|
| Compile | `mix compile` |
| Compile from clean | `mix deps.get && mix compile` |
| Full test suite | `mix test` |
| One file | `mix test test/elixir_exec/options_test.exs` |
| One test by line | `mix test test/elixir_exec/options_test.exs:42` |
| Coverage (CLI summary) | `mix coveralls` |
| Coverage (HTML, opens `cover/excoveralls.html`) | `mix coveralls.html` |
| Coverage (LCOV for CI) | `mix coveralls.lcov` |
| Static analysis | `mix credo --strict` |
| Type checking | `mix dialyzer` |
| Format | `mix format` |
| Generate ExDoc HTML to `doc/` | `mix docs` |

`preferred_cli_env` in `mix.exs` runs `dialyzer`, `coverage`, `coveralls*`, and `doctor` under the test environment automatically.

## Known gaps

- **No `LICENSE` file in repo.** `mix.exs` lists `LICENSE` in the package `:files`, and `package.licenses` declares Apache-2.0 — but no LICENSE file is committed yet. `mix hex.publish` will fail until one is added.
- **No CI workflow files.** `.github/workflows/`, `.gitlab-ci.yml`, etc. are absent. The `codecov.yml` and `coveralls.json` configurations are ready to drop into a CI step but no pipeline currently runs them.
- **No CHANGELOG entries beyond the initial release.** See [`changelog.md`](changelog.md).

## See also

- [`system-architecture.md`](system-architecture.md) — runtime structure and supervision tree.
- [`api-reference.md`](api-reference.md) — public API.
- [`configuration-guide.md`](configuration-guide.md) — option schemas defined in `lib/elixir_exec/options.ex`.
- [`testing-guide.md`](testing-guide.md) — how the test suite is structured and how to run it.
