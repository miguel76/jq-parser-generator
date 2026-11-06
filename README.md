# jq-parser-generator

A grammar-driven lexer/parser written in pure [jq](https://jqlang.org).

Give it a grammar as JSON and a stream of strings. It returns a stream of
ASTs as JSON objects:

```sh
$ echo '1 + 2*3' | jq -nRc -L . --slurpfile g grammars/arithmetic.json \
    'import "jq-parser-generator" as P; P::parse($g[0]) | P::to_sexp'
"(expression (sum (number) operator: \"+\" (product (number) operator: \"*\" (number))))"
```

- **Grammars are data.** The format is the JSON grammar format of
  [tree-sitter](https://tree-sitter.github.io/) (`src/grammar.json`), so
  existing tree-sitter grammars can often be used unchanged. The bundled
  [`grammars/json.json`](grammars/json.json) is the official tree-sitter-json
  grammar, copied verbatim. A jq DSL (`seq`, `choice`, `repeat`, …) mirrors
  tree-sitter's `grammar.js` helpers for writing grammars in jq.
- **Scannerless PEG with packrat memoisation.** There is no separate lexer
  generator to run: terminals (strings and regexes) are matched directly
  against the input, and whitespace and comments are skipped through
  `extras`.
- **Streaming.** The input is a stream of string chunks of any size. Each
  complete top-level match is emitted as soon as later input can no longer
  change it. Consumed input is discarded, so long streams of small ASTs run
  in constant memory.
- **Plain jq.** One file, no dependencies, installable with
  [jqpm](https://github.com/miguel76/jqpm).

Status: **0.1.0 prototype.** It works, has tests and resource monitoring, but
the API may still change.

## Install

With [jqpm](https://github.com/miguel76/jqpm):

```sh
jqpm add miguel76/jq-parser-generator
jqpm run -n 'import "miguel76/jq-parser-generator" as P; "x" | P::parse_string({rules: {s: "x"}})'
```

Or clone the repository and pass its directory to `jq -L`:

```sh
jq -L /path/to/jq-parser-generator 'import "jq-parser-generator" as P; ...'
```

Requires jq 1.7 or newer. The reference version is jq 1.8 (1.8.1 or newer).
Avoid jq 1.8.0: a regression in its `reduce`/`foreach`, reverted in 1.8.1,
makes it copy the parser state on every update, so parsing becomes quadratic
(about 30 s instead of 4 s for a 26 KB JSON document).

## Usage

### Parsing jq's input stream: `parse($grammar)`, `parse($grammar; $opts)`

`parse` reads the stream `., inputs`, so it consumes jq's whole input. Each
input must be a string chunk. The chunks are joined, and chunk boundaries can
fall anywhere, even inside a token.

```sh
# a file as one chunk
jq -Rs  -L . --slurpfile g grammars/json.json 'import "jq-parser-generator" as P; P::parse($g[0])' data.json

# line by line (-R drops the newlines, so put them back with {newline: true})
jq -nR  -L . --slurpfile g grammars/csv.json  'import "jq-parser-generator" as P; P::parse($g[0]; {newline: true})' data.csv

# a stream of JSON strings
echo '"1+" "2"' | jq -L . --slurpfile g grammars/arithmetic.json 'import "jq-parser-generator" as P; P::parse($g[0])'
```

### Parsing a string: `parse_string($grammar)`, `parse_string($grammar; $opts)`

`parse_string` parses `.` and nothing else:

```jq
import "jq-parser-generator" as P;
"[1, 2]" | P::parse_string($grammar)
```

### Parsing any generator: `parse_stream($grammar; $opts; chunks)`

`parse_stream` is the core function. The other entry points are built on it.

```jq
P::parse_stream($g; {start: "_value"}; "{\"a\": 1", "}  [1,", "2] 3", "4")
# => object, array, number 34   ("3" and "4" were one token split across chunks)
```

### One AST or many

The parser matches the start rule repeatedly, and every match is one AST in
the output stream. Whether the output is one AST or many therefore depends
on the grammar and the start rule.

- `grammars/json.json` starts with `document: repeat(_value)`, so a whole
  file is one `document` AST.
- `{start: "_value"}` makes each JSON value its own AST, as in JSON Lines.
  Rules whose names start with `_` are hidden: when the start rule is hidden,
  each of its child nodes is emitted on its own.
- `{single: true}` requires the start rule to match the entire input exactly
  once, like `seq(start, eof)`, and reports an error otherwise.

### Options

| option      | default      | meaning |
|-------------|--------------|---------|
| `start`     | first rule   | Name of the start rule. |
| `single`    | `false`      | The start rule must match the whole input. Exactly one AST is emitted, at end of input. |
| `newline`   | `false`      | Append `"\n"` to every chunk. Use it with `jq -R`. |
| `errors`    | `"raise"`    | `"raise"`: raise a jq error carrying a structured error object. `"emit"`: emit `{"error": {...}}` and stop. |
| `lookahead` | `0`          | Codepoints of lookahead a *failed* regex may need. Near the end of the buffer, such a failure waits for more input. See [Streaming](#streaming). |
| `backoff`   | `2`          | After an inconclusive attempt, re-parse only when the buffer has grown by this factor. Keeps chunked input linear. Set it to 1 to re-parse on every chunk. |
| `window`    | `1024`       | Size of the text window that regexes are matched against (performance tuning). |
| `memo`      | `true`       | Packrat memoisation. |

### The AST

```json
{"type": "pair", "start": 1, "end": 9, "children": [
  {"type": "string", "start": 1, "end": 4, "field": "key", "children": [
    {"type": "string_content", "start": 2, "end": 3, "text": "a"}]},
  {"type": "number", "start": 6, "end": 9, "field": "value", "text": "1.5"}]}
```

- `type` is the rule name, or the `ALIAS` value.
- `start` and `end` are offsets in Unicode codepoints from the start of the
  whole stream. `end` is exclusive.
- A node with children has a `children` array. A node without children (a
  leaf, such as a token rule) has `text` instead.
- `field` is the `FIELD` name the node was assigned to in its parent.
- Anonymous nodes (`"named": false`) exist only for literals wrapped in a
  `FIELD` or in an `ALIAS(..., named: false)`, e.g. `operator: "+"`. Other
  literals and regexes contribute text but no nodes, much like tree-sitter's
  hidden tokens.
- Hidden rules (`_name`) produce no node of their own: their children are
  spliced into the parent.

See [`examples/calc.jq`](examples/calc.jq) for a complete program that
walks an AST: a calculator built on `grammars/arithmetic.json`.

Utilities:

- `P::to_sexp` renders a tree-sitter style S-expression:
  `(pair key: (string (string_content)) value: (number))`.
- `P::nodes` yields all nodes in pre-order.
- `P::strip_positions` removes `start` and `end`.

### Errors

```json
{"message": "syntax error at line 1, column 7: expected \"[\" or ... or number, found \"]\"",
 "position": 6, "line": 1, "column": 7,
 "expected": ["\"[\"", "\"\\\"\"", "\"false\"", "\"null\"", "\"true\"", "\"{\"", "number"],
 "found": "\"]\""}
```

The error is reported at the furthest position any alternative reached,
which is the standard PEG heuristic. `expected` lists the terminals that
failed there. A rule whose whole body is a regex or a `TOKEN` is listed by
its rule name. Catch errors with `try ... catch .message`, or use
`{errors: "emit"}`.

Grammar problems raise `jq-parser-generator: ...` errors when the grammar is
compiled: undefined symbols, invalid regexes, unknown rule types and **left
recursion** (see below).

## Grammars

Bundled grammars, in [`grammars/`](grammars/):

| grammar | language | notes |
|---------|----------|-------|
| `json.json` | JSON | the tree-sitter-json grammar, verbatim |
| `arithmetic.json`, `csv.json` | examples | |
| `sparql11.json` | SPARQL 1.1 Query and Update | start rules `QueryUnit` and `UpdateUnit`. Passes all 258 positive W3C syntax tests |
| `jq.json` | jq 1.8 | parses all of jq 1.8's test programs and its `builtin.jq` |

`sparql11.json` and `jq.json` are generated from jq DSL sources in
`grammars/src/` with `make grammars`. See
[docs/sparql-and-jq.md](docs/sparql-and-jq.md) for how they were validated
and what they showed is still missing in the library.

See [docs/grammar-format.md](docs/grammar-format.md) for the full reference.
In short, a grammar is a tree-sitter `grammar.json`:

```json
{
  "name": "arith",
  "rules": {
    "sum":    {"type": "SEQ", "members": [
                {"type": "SYMBOL", "name": "number"},
                {"type": "REPEAT", "content": {"type": "SEQ", "members": [
                  {"type": "FIELD", "name": "op", "content": {"type": "STRING", "value": "+"}},
                  {"type": "SYMBOL", "name": "number"}]}}]},
    "number": {"type": "PATTERN", "value": "[0-9]+"}
  },
  "extras": [{"type": "PATTERN", "value": "\\s"}]
}
```

Rule types: `STRING`, `PATTERN`, `SYMBOL`, `SEQ`, `CHOICE`, `REPEAT`,
`REPEAT1`, `BLANK`, `FIELD`, `ALIAS`, `TOKEN`, `IMMEDIATE_TOKEN`, `PREC*`
(ignored), `RESERVED` (ignored), `EOF`, plus two PEG extensions: `AND` and
`NOT`. As shorthands, a bare JSON string is a `STRING` and a JSON array is a
`SEQ`.

The same grammar written with the jq DSL:

```jq
include "jq-parser-generator";
{rules: {
  sum: seq([sym("number"), repeat(seq([field("op"; str("+")), sym("number")]))]),
  number: pat("[0-9]+")
}}
```

### Semantics compared with tree-sitter

tree-sitter compiles a grammar to a GLR parser with a context-aware lexer.
This library interprets the same grammar as a **Parsing Expression Grammar**.
The differences:

- `CHOICE` is *ordered*: the first alternative that matches wins. Inside
  `TOKEN` and `IMMEDIATE_TOKEN`, the *longest* alternative wins, as in a
  lexer.
- `REPEAT` is greedy and never gives back what it matched.
- **Left recursion is not supported.** A rule like
  `expr: seq(expr, "+", expr)` is rejected at compile time. Write
  repetitions instead (`seq(term, repeat(seq("+", term)))`) and express
  precedence by layering rules: see `grammars/arithmetic.json`.
- `PREC*` values are ignored, and `conflicts`, `precedences`, `inline`,
  `supertypes`, `word` and `externals` are accepted but have no effect.
- `extras` are skipped before every terminal, except inside tokens. They
  default to `\s`, like in tree-sitter, and produce no nodes. Comment nodes,
  in particular, are dropped.
- Regex flags: only `i` (and `x`) are honoured. Regexes use Oniguruma, jq's
  regex engine, which accepts JavaScript-style patterns in most practical
  cases.

## Streaming

After each chunk, the parser tries to match the start rule at the start of
the buffered text. It records the furthest character any terminal looked at.
A successful match is **final**, and is emitted, if no terminal needed to
look at or past the end of the buffer. In that case no future input can
change the match. A token that runs up to the end of the buffer, such as
`12` followed by a chunk `34`, makes the parser wait for more input.

One case cannot be detected: a regex that *fails* because its match would
need characters that have not arrived yet. For example, `ab+c` against a
buffer ending in `abb`. By default a failed regex is assumed to be decided
by its first character. You can:

- split long tokens into a sequence of short pieces, as tree-sitter grammars
  do for strings: `seq('"', repeat(choice(/[^"\\]+/, escape)), '"')`.
  Repetitions that reach the end of the buffer are handled correctly; or
- set `{lookahead: n}`, so that regex failures within `n` codepoints of the
  end of the buffer wait for more input.

## Performance

These figures come from `python3 tests/run_tests.py --bench` on one core of
a cloud VM. jq 1.8.1 is the reference version; the jq 1.7 figures were
measured earlier on the same kind of machine and are kept for comparison:

| workload | throughput, jq 1.8.1 | throughput, jq 1.7 | peak memory, jq 1.8.1 | peak memory, jq 1.7 |
|---|---|---|---|---|
| JSON document, tree-sitter-json grammar | ~4.1 KiB/s | ~6.4 KiB/s | ~0.5 KiB per input byte (linear) | ~0.5 KiB per input byte (linear) |
| JSON Lines stream (`start: "_value"`), 42 KB | ~5.5 KiB/s | ~8.8 KiB/s | ~4 MiB, constant | ~5 MiB, constant |
| JSON document fed line by line | ~2.7 KiB/s | ~4 KiB/s | linear | linear |
| flat list of 20k one-char items | ~7.2 KiB/s | ~11 KiB/s | 27 MiB | 28 MiB |

jq 1.8.1 is about 1.6× slower than jq 1.7 on these workloads, with the same
memory use. Avoid jq 1.8.0: its `reduce`/`foreach` regression makes parsing
whole documents quadratic (about 30 s instead of 6 s for a 26 KB document).

Time is linear in the input size, and the test suite asserts this. The
constant factor is that of an interpreter running inside jq, so the library
suits configuration files, DSLs and moderately sized inputs, not
multi-megabyte documents. Some implementation notes on keeping jq linear are
in [CLAUDE.md](CLAUDE.md).

### Other jq implementations

gojq 0.12.20 and jaq 3.1.2 run the full test suite in CI, including the
resource tests. gojq parses a 26 KB JSON document about as fast as jq 1.8.1;
jaq is about half as fast (~2.6 KiB/s) and uses about twice the memory
(~1.1 KiB per input byte, still linear; streams stay at ~18 MiB). fq 0.18.0,
which is built on gojq, passes the functional tests when run by hand.
Caveats:

- **Object key order.** gojq keeps object keys sorted, so the default start
  rule (the first rule in the grammar) becomes the alphabetically first
  one. Pass the start rule explicitly: `{start: "document"}` in the options,
  or `"start"` in the grammar.
- **Regex lookahead.** gojq uses Go's `regexp` and jaq Rust's `regex`;
  neither has lookaround. Grammars whose patterns use `(?!…)` or `(?=…)`
  fail to compile there. This includes the bundled SPARQL and jq grammars
  (`grammars/sparql11.json`, `grammars/jq.json`), which are jq-only for now.
  Use `not_followed_by` / `followed_by` in the grammar instead of regex
  lookahead.
- **jaq module paths.** jaq resolves `import "a/b"` only to `a/b.jq`, not to
  `a/b/b.jq` as jq does, so with jqpm's layout import the module by its full
  path: `import "miguel76/jq-parser-generator/jq-parser-generator" as P;`.
  jaq also has no `modulemeta`.
- **fq** cannot import JSON data modules (`import "grammars/json" as $g`)
  and has no `--slurpfile`. Pass grammars with `--argjson` instead. Read raw
  text with `-d bytes` and `tostring`.

## Development

```sh
make test         # jq --run-tests suite + CLI tests + resource tests
make test-jq      # only the jq-native functional tests (fast)
make bench        # resource report (CPU time, peak RSS, throughput)
```

- `tests/conformance.py` runs external corpora (the W3C SPARQL test
  suite, jq's own tests) through the bundled SPARQL and jq grammars; see
  [docs/sparql-and-jq.md](docs/sparql-and-jq.md).
- `tests/parse.test` holds the functional tests in jq's own `--run-tests`
  format.
- `tests/run_tests.py` uses only the Python standard library
  (`python3 -m pytest tests/run_tests.py` also works). It runs the jq suites, end-to-end CLI tests and the resource
  tests, which check CPU time and peak RSS of each jq process: absolute
  budgets, linear scaling, and constant memory for streams. Use
  `JQPG_PERF_SLACK=3` on slow machines, and `JQPG_PERF_REPORT=report.json`
  to save the measurements.

## Prior art and design notes

See [docs/prior-art.md](docs/prior-art.md) for the survey of existing jq
parsing libraries and grammar representations that informed this design.

## License

GPL-3.0, see [LICENSE](LICENSE). `grammars/json.json` is the tree-sitter-json
grammar, © Max Brunsfeld, MIT licensed: see
[grammars/LICENSE.tree-sitter-json](grammars/LICENSE.tree-sitter-json).
