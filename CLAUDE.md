# CLAUDE.md

Guidance for AI assistants (and humans) working on this repository.

## What this is

`jq-parser-generator` is a grammar-driven PEG parser written in **pure jq**.
Grammars are JSON in tree-sitter's `grammar.json` format. The library is one
jq module, packaged for [jqpm](https://github.com/miguel76/jqpm).

## Layout

```
jq-parser-generator.jq   the whole library (jqpm entry point: <repo>.jq at the root)
jqpackage.json           jqpm manifest (name, version, main, dependencies)
grammars/                bundled grammars (json = tree-sitter-json verbatim, MIT; arithmetic; csv;
                         sparql11 and jq, generated from grammars/src/*.jq by `make grammars`)
tests/parse.test         functional tests, jq --run-tests format
tests/run_tests.py       stdlib-only runner: jq suites + CLI tests + resource tests
tests/conformance.py     external corpora (W3C SPARQL tests, jq's tests) vs the bundled grammars
docs/                    grammar-format.md (reference), prior-art.md (survey + design rationale),
                         sparql-and-jq.md (SPARQL/jq grammars: validation results, missing features)
```

## Commands

```sh
make test-jq    # jq -L . --run-tests tests/parse.test   (~2 s)  run after every change
make test       # everything, including resource tests (~35 s)
make bench      # resource report only
```

The reference jq is **1.8** (1.8.1 or newer). Pass another binary with
`make test JQ=/path/to/jq`. jq 1.7, gojq and jaq must keep working (CI runs
all four). gojq and jaq have no `--run-tests`: `make test-jq` and the runner then
run each case as its own process and compare outputs as JSON. jq 1.8.0 passes the
functional tests, but its `reduce`/`foreach` copy the state on every update
(jqlang/jq#3205, reverted in 1.8.1), so the runner skips resource tests on
it unless `JQPG_PERF_FORCE=1` is set.

`JQ=<jq> python3 tests/conformance.py jq-roundtrip <jq source checkout>`
re-runs jq's test programs with the binary in `JQ`; use a jq 1.8 binary,
the version the bundled jq grammar targets.

Tests run from the repository root with `-L .`, so the module is imported as
`import "jq-parser-generator" as P;` and data grammars as
`import "grammars/json" as $g;` (then `$g[0]`).

## jqpm conventions (do not break)

- The entry point must stay `jq-parser-generator.jq` at the repository root.
  Users import it as `import "miguel76/jq-parser-generator" as P;` with
  `-L jq_modules`.
- Keep the library in a single file, or use only `./`-relative imports,
  which jqpm rewrites at install time.
- Version in three places, kept in sync: `jqpackage.json` `version`, the
  `module {...}` metadata at the top of the `.jq` file (checked by
  `test_manifest`), and a semver git tag `vX.Y.Z` when releasing.
- No runtime dependencies. If one is ever added, declare it in
  `jqpackage.json` `dependencies`.

## Architecture (jq-parser-generator.jq)

1. **DSL** (`seq`, `choice`, `repeat`, …): constructors for grammar JSON.
2. **`compile_grammar`**: normalises shorthands (string → STRING,
   array → SEQ), unwraps PREC/RESERVED, precomputes literal codepoints,
   anchored regexes (`\A(?:…)`) and error labels, and validates: undefined
   symbols, bad regexes, and left recursion (nullable fixpoint + leftmost-call
   graph closure). It is idempotent (`compiled: true`).
3. **`_attempt`**: one top-level match of the start rule from position `$p0`
   over a codepoint array. `_m($rule; $tok)` is the recursive PEG
   interpreter. `$tok` means "inside a token": no extras, no error
   recording, longest-match CHOICE.
4. **`parse_stream`**: a `foreach` over the chunks plus an EOF event. It
   buffers text, runs attempts, emits final matches, discards consumed
   input, keeps line/offset bookkeeping, and applies back-off.
5. **`parse`, `parse_string`**: thin wrappers. `parse` reads `., inputs`.

Engine state (threaded through `_m`):
`{ok, pos, kids, first, far, exp, touch, memo, sx, lb}`

- `kids` is a cons list `[node, rest, length]`.
- `first` is where the first terminal of the current node started, so
  leading extras are excluded from `start`.
- `far` and `exp` hold the furthest failure and the labels expected there.
- `touch` is the furthest index any terminal examined. `touch >= len` means
  "needs more input" for streaming.
- `sx` caches the last extras-skip result.
- `lb` is a stack for longest-match choices.

## jq performance rules (measured; violating them makes parsing quadratic)

- **Never slice strings in hot code.** `$s[i:j]` is O(i) (jq 1.7 and 1.8). Work on
  the exploded codepoint array (`$cps`). Regexes run on `$blocks[k][off:]`,
  which is bounded by `2*window`.
- **Never hold a reference to the whole state** while updating it. Do not
  write `. as $s`. Snapshot only the fields you need:
  `{pos, kids, first} as $b`. Otherwise every `.memo[$k] = …` copies the
  memo table.
- **Do not use `a // b` (or `//=`) on engine state.** A truthy `a` leaves a
  backtracking point alive that pins `.`. Use
  `if a == null then b else a end`.
- Avoid generators that stay open across updates, e.g.
  `(x, y) as $v | <update .>`.
- Do not append to arrays that a snapshot also references. Use the cons list.
- **No large flat objects or arrays that grow during a parse.** gojq never
  updates in place: every update copies the container. The memo table is
  therefore a trie over the position (`_mpath`: arrays of 32 slots per
  base-32 digit, a `{rule: entry}` object per position at the leaves).
- **In loop bodies (reduce, foreach, until), run `_m` as
  `if $lazy then last(_m(…)) else _m(…) end`** (`_drain($lazy; …)` outside
  the hot path). jaq keeps the iterator of every update open until the loop
  ends (an update may yield more outputs), which holds the memory of the
  whole parse; `last` drains it. `$lazy` comes from a probe in
  `parse_stream` and is false in jq and gojq, where `last` only costs time.
  Write it inline: a def with a closure argument costs jq 5–10%. Not
  `first(…)`: in jq its `., break` fork stays open inside `until` and pins
  the state.
- jaq's `setpath` neither turns null into a container nor grows an array
  past its end. `_mnew` creates the trie levels first, only when the
  `$mkpath` probe says so (the walk costs jq ~5%).
- Do not rely on object key order (`keys_unsorted`, the first rule as
  start) beyond `compile_grammar`'s default: gojq sorts keys.
- After touching the engine, run `make bench`. The resource tests assert
  linear scaling and constant memory for streams.

## Semantics to preserve

- Ordered CHOICE. Longest-match CHOICE inside TOKEN/IMMEDIATE_TOKEN.
  Greedy REPEAT.
- Hidden rules (`_x`) splice their children. A hidden start rule emits each
  child as a separate AST.
- Positions are codepoint offsets from the start of the whole stream.
- A match is emitted only when it is final (`touch < len`) or at EOF. A
  regex failure is assumed to be decided by its first character unless the
  `lookahead` option is set.
- Errors: `{message, position, line, column, expected, found}`, raised with
  `error(obj)` or emitted as `{error: obj}` with `errors: "emit"`. Grammar
  errors are strings prefixed with `jq-parser-generator: `.

## Writing tests

- Prefer adding cases to `tests/parse.test`. Each case is a program line,
  an input line and the expected output line(s), separated by a blank line.
  Programs must fit on a single line. Use `try … catch` for runtime errors.
  `%%FAIL` is only for compile errors of the test program itself.
- Give multi-rule grammars an explicit `start`. A case that really tests
  key order gets a `# needs: key-order` comment line right before it; the
  emulated runner skips it on gojq.
- CLI behaviour (`-R`, `-n`, `inputs`, exit codes) goes in `CliTests` in
  `tests/run_tests.py`.
- New performance-sensitive features need a `ResourceTests` case: record()
  the measurement, assert a budget scaled by `SLACK`, and, where it makes
  sense, a scaling ratio, which is never scaled.

## Roadmap / known limitations

See docs/sparql-and-jq.md for the full list found by the SPARQL/jq grammars,
including the open bug: `{single: true}` on empty (or extras-only) input
emits nothing, even if the start rule can match the empty string.

- No left recursion. Idea: precedence climbing for rules using PREC_LEFT /
  PREC_RIGHT, so that tree-sitter expression grammars load unchanged.
- Extras produce no nodes (comments are dropped).
- `word`, `conflicts`, `externals` and `precedences` are ignored.
- Throughput is about 3–7 KiB/s on jq 1.8.1 (5–10 KiB/s on jq 1.7). Possible speed-ups: FIRST-set prefiltering
  of CHOICE alternatives, caching extras skips per position, fewer
  allocations per node.
- Tested against jq 1.7, jq 1.8, gojq and jaq. CI runs jq 1.8.1, Ubuntu's
  jq, gojq 0.12.20 and jaq 3.1.2. fq passes the functional tests but is not
  in CI. The SPARQL and jq grammars use regex lookahead, which gojq and jaq
  lack, so they are jq-only and their CLI test is skipped there. jaq has no
  `modulemeta` and does not resolve `import "a/b"` to `a/b/b.jq`; the runner
  probes both (`has_modulemeta`, `resolves_dir_modules`).
