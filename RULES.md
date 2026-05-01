# General Principles

## Establish understanding before acting

Before taking action on any request, build a picture of the current state from available evidence: existing files, configuration, prior context, or error messages.

When evidence is insufficient, locate and read relevant documentation before proceeding.

When no authoritative document exists and evidence is still insufficient, surface the open question and wait for a resolution before proceeding. Accuracy takes priority over speed: a decision built on an unresolved question does not save time.

---

## Show state and state changes, do not only describe them

When explaining what something does or what will change, show the literal state: the actual value, structure, output, or condition before and after. A reader should be able to understand what will change at a glance, without having to reconstruct it from a verbal account.

Reserve prose for explaining why. Use literal representations to show what.

---

## Illustrate explanations with examples and diagrams

Use examples and diagrams generously when explaining. An example makes a point concrete; a diagram makes structure and relationships visible. Both remove ambiguity that prose alone cannot resolve.

---

## Write rules and instructions at the level of general principles

Express rules and instructions in terms of intent and reasoning, not tied to a specific language, framework, or tool.

Use neutral wording that does not imply a particular syntax, convention, or ecosystem. Avoid symbols, operators, or notation that could be confused with programming language constructs.

Express a rule in terms of why the behavior matters, not only what to do.

---

# Development Workflow

## Write a behaviour spec before implementation

Before writing any implementation code, determine whether the required behavior is explicit enough to define module and function specs:

- If the required behavior is explicit enough, proceed to defining specs directly.
- If the required behavior is not explicit enough to define specs, create a behaviour spec before proceeding.
- If there is insufficient information to create a behaviour spec, use example mapping to surface the behavior first, then create the behaviour spec.

**Exceptions**: changes with no integration surface:

- Mechanical fixes with no logic change (typos, renaming within a single function)
- Adding comments or log statements

---

## Fill out a coding task template before writing code

Before writing any code, document a spec for every function and module being created or modified. Each spec defines the purpose, public interface, inputs, outputs, and behavioral contract. When a spec already exists for a module or function being modified, read the current implementation, verify the spec against it, and update any spec that has drifted before using it as the implementation contract.

After coding, validate the implementation against each spec. Update any spec that drifted during implementation.

---

## Create a timestamped checklist when working on complex tasks

When a task has multiple distinct steps, spans several files, or could take more than a few tool calls to complete, create a checklist at the outset. Record a start and completion timestamp for each item. Update the checklist in place as work progresses.

Checklist format:

```
- [ ] HH:MM: Item description
- [x] HH:MM-HH:MM: Completed item description
```

---

## Explore the solution space before committing to a direction

When a task involves building something new -- a feature, a component, an integration, a design -- do not move directly to implementation. First explore the problem space: what approaches are possible, what tradeoffs exist, what constraints apply, and what unknowns remain. Only after this exploration should a direction be chosen and implementation begin.

This applies to any creative or design work. It does not apply to purely mechanical changes where the solution is already determined.

---

## Write a plan before touching code on multi-step tasks

When a task has requirements or a spec and involves more than a trivial change -- multiple files, multiple components, or coordinated changes -- write a plan before writing any implementation. The plan should define scope, approach, and sequence. Implementation begins only once the plan is agreed upon.

---

## Write tests before implementation code

When implementing any feature or fixing any bug, write the tests first. Tests define the contract the implementation must satisfy. Implementation code is written to make those tests pass, not the other way around.

---

## Investigate before proposing a fix

When facing a bug, test failure, or unexpected behavior, resist the impulse to immediately propose a solution. Form a hypothesis about the cause, gather evidence to test it, and confirm the root cause before writing any fix. A fix applied to the wrong cause creates new problems without resolving the original one.

---

## Verify work before declaring it complete

Before stating that a task is done, finished, or passing, verify the work against the original requirements. Run the relevant tests. Confirm that the acceptance criteria are satisfied. Do not claim completion based on the absence of visible errors alone.

---

## Request a review before integrating significant work

When a meaningful implementation is finished -- a new feature, a major change, or work targeted at a shared branch -- seek a code review before merging or finalizing. The review is a gate, not a formality.

---

## Understand review feedback before acting on it

When receiving code review feedback, read and understand each comment fully before making any change. If the intent of a comment is unclear, resolve the ambiguity first. Treat feedback as a signal to think, not only to act.

---

## Follow a structured process when a branch is ready to integrate

When all tests pass and implementation is complete on a branch, follow a deliberate process before merging: confirm the scope of changes, verify nothing was missed, and decide the right integration path. Do not merge simply because the code works.

---

## Parallelize independent work

When facing two or more tasks that do not share state and do not depend on each other, work on them in parallel rather than sequentially. Sequential execution of independent tasks wastes time and delays feedback.

---

## Isolate feature work from the main workspace

When starting work on a feature, or executing an implementation that could affect current working state, work in an isolated copy of the repository. This protects uncommitted work from interference and keeps the main workspace stable.

---

## Delegate independent tasks when executing a plan

When executing a plan with multiple independent tasks, decompose and delegate them so they can be worked in parallel. Coordinate at integration points. Do not work through independent steps one by one in a single thread when they could be executed concurrently.

---

## Enumerate files before starting any implementation work

When the work involves writing or modifying code, the first action is to list every file that will be created or modified. Each file on that list will be handled by exactly one dedicated agent. No implementation begins until the list is complete.

This is distinct from general planning: the file list is not a planning artifact, it is the dispatch plan. Exploration, spec writing, and all other preparation exist to give each file's agent what it needs. Do not begin exploration, spec writing, or any other preparation until the file list exists.

---

# Code Design

## Design against public contracts, not internal representations

At any code boundary, depend only on the public contract: the shape callers pass in and the shape they receive back.

This applies everywhere code crosses a boundary: function inputs, return values, test assertions, interface definitions, and module dependencies. Never couple to internal representations, intermediate forms, or implementation details.

---

# Claude Code

## Delegate code changes to the code-implementer agent

When making any change to elixir code in this project, delegate the implementation to the `claude-copilot:code-implementer` subagent rather than writing code inline.

This applies to new features, bug fixes, refactors, and any edit that modifies executable code. It does not apply to configuration-only changes, documentation edits, or changes to non-code files.

---

## Claude Code agents orientation

Before working with Claude Code agents, fetch the current Anthropic documentation. Orient on:

1. **Isolation model**: what an agent can and cannot see, what context it inherits, and what is withheld
2. **Trust boundaries**: which agents can call which tools, and what elevated permissions must be explicitly granted
3. **Communication patterns**: how agents pass results back and what is guaranteed vs. best-effort
4. **Security constraints**: prompt injection from agent outputs, over-broad tool grants, and side effects from parallel agents touching shared state
5. **When not to use agents**: inline execution is faster and simpler; agents add overhead and coordination cost

If the documentation and your training knowledge conflict, trust the fetched documentation.

---

## Claude Code skills orientation

Before working with Claude Code skills, fetch the current Anthropic documentation. Orient on:

1. **Current API shape**: how skills are structured in the version of Claude Code in use
2. **Security constraints**: what a skill is and is not permitted to do, particularly around file access, shell execution, and outbound network calls
3. **Best practices**: design patterns the Anthropic team has validated, including progressive disclosure and the principle of least surprise
4. **Changes**: any behavior that differs from a prior version

If the documentation and your training knowledge conflict, trust the fetched documentation.

---

# Elixir

## Run quality checks after every code change

After editing, creating, refactoring, or fixing any Elixir code, run quality checks for the current stage of work. Tests are the first check and are mandatory; style and type analysis follow only once tests pass.

Do not defer checks to move faster -- a regression discovered later costs more to fix than running checks now.

---

## Layer test execution from narrow to broad

When running tests to verify an Elixir code change, start at the narrowest scope that proves the change works: the specific test at its line number. Once that passes, expand to the full test file. Expand to the app only when the change affects the whole module. Expand to the entire project only when the change has cross-cutting reach -- a shared dependency, an interface change, or a refactor that could affect other callers.

A targeted test run is faster and its failure output is clearer. Widening scope beyond what the change warrants slows down iteration and obscures which module caused the failure.
