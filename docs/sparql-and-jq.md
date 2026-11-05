# Parsing SPARQL 1.1 and jq 1.8

This document records an experiment: can jq-parser-generator parse two real
languages, SPARQL 1.1 (Query and Update) and jq 1.8, and what is missing?

**Short answer: yes, both parse.** Both grammars accept every syntactically
valid input in the official test suites, and reject every input that has a
context-free syntax error. The inputs they wrongly accept all break *static
semantics* rules: variable scoping, constant checks, label reuse. No
context-free grammar can express those, and real implementations check them
after parsing. Getting there needed one library bug fix and a number of
grammar-level workarounds. The workarounds are listed below as the library's
missing features, most important first.

| | grammar | positive tests (must parse) | negative tests (must be rejected) | throughput |
|---|---|---|---|---|
| SPARQL 1.1 | [`grammars/sparql11.json`](../grammars/sparql11.json) (source: [`grammars/src/sparql11.jq`](../grammars/src/sparql11.jq)) | **258 / 258** | 83 / 112, all 29 misses are static semantics | ~0.5–1 KB/s |
| jq 1.8 | [`grammars/jq.json`](../grammars/jq.json) (source: [`grammars/src/jq.jq`](../grammars/src/jq.jq)) | **820 / 820**, incl. jq's own `src/builtin.jq` | 8 / 19, all 11 misses are compile-time checks | ~1 KB/s |

## Usage

```sh
# SPARQL query (start rule QueryUnit) or update ({start: "UpdateUnit"})
jq -Rs -L . --slurpfile g grammars/sparql11.json \
  'import "jq-parser-generator" as P; P::parse_string($g[0]; {single: true}) | P::to_sexp' query.rq

# jq program
jq -Rs -L . --slurpfile g grammars/jq.json \
  'import "jq-parser-generator" as P; P::parse_string($g[0]; {single: true}) | P::to_sexp' prog.jq
```

```
$ echo '.a as $x | 1 + 2 * 3, -$x' | jq -Rr -L . --slurpfile g grammars/jq.json \
    'import "jq-parser-generator" as P; P::parse_string($g[0]; {single: true}) | P::to_sexp'
(program (binding source: (field) (variable) body: (comma (additive (number) operator: "+"
  (multiplicative (number) operator: "*" (number))) (negation (variable)))))
```

Both grammars are written with the jq DSL and generated with `make grammars`.
A test checks that the committed JSON is up to date.

## How the grammars were validated

[`tests/conformance.py`](../tests/conformance.py) runs external corpora,
which are not vendored:

```sh
git clone --depth 1 https://github.com/w3c/rdf-tests
python3 tests/conformance.py sparql rdf-tests/sparql -v      # SPARQL 1.0 + 1.1 syntax tests

git clone --depth 1 --branch jq-1.8.0 https://github.com/jqlang/jq
python3 tests/conformance.py jq jq -v                        # tests/*.test + src/builtin.jq
python3 tests/conformance.py jq-roundtrip jq                 # checks tree shape, see below
```

- **SPARQL**: every `Positive/Negative(Update)SyntaxTest(11)` entry in the
  `sparql10` and `sparql11` manifests of the W3C test suite (370 tests).
- **jq**: every program in jq 1.8.0's `tests/*.test` files. Programs under
  `%%FAIL` are negative tests. The suite also parses `src/builtin.jq`
  (9.6 KB of real jq).
- **jq tree shape (round trip).** Accepting a program does not prove that
  the tree is right. `jq-roundtrip` therefore prints every parsed test
  program back with an explicit pair of parentheses around every operator
  node. It then runs the original and the re-printed program with the local
  `jq` binary and compares the outputs. With jq 1.7: 562 programs behave
  the same. 13 differ, and in each of them the re-printed program produces
  **jq 1.8's** expected output, while the original fails or gives the 1.7
  result. These 13 tests cover 1.8's new precedence for `… as $x | …` and
  for object values. The parentheses make that precedence explicit, so
  jq 1.7 computes the 1.8 answer. Swapping the precedence of `|` and `,` in
  the grammar makes 8 programs differ, so the check does detect errors.

### SPARQL: the 29 negative tests that are accepted

| static rule (SPARQL 1.1 §18–19) | tests |
|---|---|
| A blank node label is used in only one basic graph pattern, and not across operations of one update request | 12 (`syn-bad-34`…`38`, `syn-blabel-cross-*`, `syn-bad-*-breaks-BGP`, `syntax-update-54`) |
| A projection that is not grouped or aggregated in a grouped query | 9 (`agg08`…`agg12`, `group06`, `group07`, `syn-bad-01`, `syn-bad-02`) |
| Variable already in scope: `BIND`, `SELECT (… AS ?x)`, duplicate projections | 6 (`syntax-BINDscope6`…`8`, `syntax-SELECTscope2`, `syn-bad-03`, `syn-group-by-values-scope-03`) |
| `VALUES` rows must match the number of variables | 2 |

All of these are walks over the AST, which is JSON, so a jq function could
check them. That would be a separate SPARQL validator, not part of the
parser.

Rules that *are* context-free but sit in the spec's notes, not in its EBNF,
are enforced:

- no variables in `INSERT DATA` / `DELETE DATA`;
- no blank nodes in `DELETE DATA` / `DELETE WHERE` / `DELETE {…}`;
- tokenizer longest match (`?x<?a&&?b>?y` contains the IRI `<?a&&?b>`);
- `\u` escapes that would encode a surrogate are rejected.

### jq: the 11 negative tests that are accepted

They are all compile-time errors that jq raises after parsing:
`$bar is not defined`, `$*label-foo is not defined`,
`Cannot use number (0) as object key`, `Module metadata must be constant`,
`Module metadata must be an object`, `Import path must be constant`, and an
imported module that has its own syntax error. Every syntax error in the
suite is rejected, for example `{`, `}`, `%::wat`, `. as [] | null`, and
the invalid escape `"\v"`.

## What is missing in the library

Ordered by how much they mattered for these two languages.

### 1. Bugs found (one fixed)

- **Fixed in this branch:** a `FIELD` or `ALIAS` that failed to match did
  not restore the engine's `first` marker. So `optional(field(...))` gave
  the enclosing node a wrong `start`: in jq's `.[-2:]`, the slice started
  at the `]`. The round-trip test found it. Regression tests are in
  `tests/parse.test`.
- **Open:** with `{single: true}`, input that is empty or contains only
  extras emits nothing: no AST and no error, even when the start rule can
  match the empty string. A SPARQL update that is only a comment is valid,
  and so is an empty jq program. Without `single`, an empty match is
  reported as an error (`expected non-empty …`). Suggested fix: in `single`
  mode, run the attempt at end of input when no AST has been emitted yet.

### 2. Operator precedence: no `PREC_*`, no left recursion

jq's grammar is a bison grammar: left-recursive, with 13 `%left` /
`%right` / `%nonassoc` / `%precedence` declarations. The library ignores
`PREC*` and rejects left recursion, so the grammar was rewritten by hand:
one rule per level (`alternative`, `assignment`, `or`, `and`, `comparison`,
`additive`, `multiplicative`), a separate layer for `|` / `,` and for the
forms that extend as far right as possible (`def …;`, `… as $x |`,
`label $x |`), and a postfix-term rule for `try`, unary minus and suffixes.
This is the most error-prone part, and it needs the round-trip test to be
trusted. SPARQL's grammar is already LL(1) and was not affected.

Consequences:

- Binary operators produce **flat n-ary nodes**: `1 - 2 - 3` is
  `(additive (number) "-" (number) "-" (number))`. The consumer has to fold
  them according to each level's associativity.
- Non-associativity (`1 == 2 == 3` is an error in jq) has to be encoded by
  the grammar's shape.

Suggested: precedence climbing for left-recursive rules annotated with
`PREC_LEFT` / `PREC_RIGHT` (already on the roadmap). tree-sitter expression
grammars, such as tree-sitter-jq, would then load unchanged, and the
binary nodes would come out nested.

### 3. No way to create a node only when it is needed

Without left recursion, every precedence level is a rule. If every level
made a node, `?x` in a SPARQL `FILTER` would be 10 nested nodes deep. Both
grammars use an idiom (`level()` in the sources) instead: a hidden rule
`_x: choice(x, operand)` with `x: seq(operand, repeat1(op operand))`. It
works, but doubles the rules and adds a memo entry per level. Suggested:
honour tree-sitter's `inline`, or add a rule flag such as "make a node only
if there are two or more children".

### 4. Keywords: `word` is ignored

A keyword must not match the start of a longer identifier (`iffy`,
`selectx`, `select:x`). tree-sitter handles this with `word`; here every
keyword carries its own `NOT` lookahead (`kw()` in the sources). Identifiers
also need a regex that excludes the reserved words (jq). Suggested: honour
`word`. A `STRING` that matches the `word` rule's regex must then end at a
word boundary, and the `word` rule rejects reserved strings.

### 5. No case-insensitive literals

SPARQL keywords are case-insensitive, so each one is a `PATTERN` with the
`i` flag. Error messages then show raw regexes, for example
`expected /(?:true)(?![A-Za-z0-9_:…])/ or IRIREF or …`. Suggested: a
`flags: "i"` option on `STRING`, with the label still `"true"`.

### 6. Error messages: no display names, and predicates leak

- Expected-sets cannot be labelled. A terminal's label is its literal, its
  regex, or the enclosing rule's name. Suggested: an optional `label` on any
  rule, or use the `ALIAS` value as the label.
- A failed `NOT` predicate is recorded as an expectation `!(...)`. For jq,
  `1 == 2 == 3` reports `expected !(...), found "= 3"`; jq says
  `unexpected ==`. Suggested: do not record predicate failures as
  expectations, or record what the predicate's content expected.

### 7. Longest match across terminals has to be emulated

A scannerless PEG picks terminals in grammar order, while both languages
are specified with a longest-match tokenizer. Every place where one
terminal is a prefix of another needed a lookahead:

- jq: `|` vs `|=`, `/` vs `//` and `/=`, `=` vs `==`, `?` vs `?//`
  (`.a?//1` is a syntax error in jq), `.` vs `..` / `.5` / `.foo`, and
  `$__loc__` vs `$__loc__x`;
- SPARQL: `<` and `<=` vs `IRIREF`, the path modifier `?` vs a variable
  `?x`, and `a` vs `a:b`.

Each was handled with a `NOT` predicate, and the conformance suites check
them. Suggested: declare a set of terminals (or reuse `word`) that are
matched with longest-match semantics.

### 8. No parametric rules

SPARQL Update templates come in variants: with or without variables, with
or without blank nodes. The library has no rule parameters, so the jq
source generates 4 copies of 14 rules (`template_rules()`). The copies are
`ALIAS`ed back to their base names, so the AST does not show the suffixes.
This works well because grammars are data and the DSL is jq. It is a
convenience to add, not a blocker.

### 9. Lexer-level details

- **Text inside tokens:** jq strings contain interpolations
  (`"a\(.b)c"`), so a string cannot be a single `TOKEN`. Each piece has to
  be an `IMMEDIATE_TOKEN`, otherwise extras are skipped *inside* the
  string: `"#x"` would start a comment. This works, but is easy to get
  wrong. Comments are dropped, because extras make no nodes. That is fine
  for these tests, but a formatter or linter needs comment nodes.
- **Pre-lexing transforms cannot be expressed:** SPARQL 1.1 §19.2 replaces
  `\uXXXX` escapes anywhere in the query text before tokenizing. The
  grammar does what SPARQL 1.2 does instead: it accepts `UCHAR` escapes in
  IRIs and strings only, which covers every test. A pre-pass in jq
  (`gsub`) would shift the AST positions.

### 10. Performance

| | time |
|---|---|
| compile the grammar (`compile_grammar`) | jq 0.08 s, SPARQL 0.37 s (the result can be cached: it is idempotent JSON) |
| typical SPARQL query (0.6 KB) | ~0.6 s after compiling |
| SPARQL query of 3.2 KB / 40 KB | 7 s / 103 s |
| jq's `src/builtin.jq` (9.6 KB) | 9.4 s |
| whole SPARQL suite (370 files) / jq suite (839 programs), one process | 19 s / 37 s |

Time stays roughly linear in input size, thanks to memoisation (without
memoisation, a 3 KB query does not finish). But these grammars are 3–7× slower
than the bundled JSON grammar measured on the same machine (3.3 KB/s). The
cause is wide
choices that try one regex per alternative. SPARQL's `BuiltInCall` has 55
keyword alternatives, and every keyword is a case-insensitive regex with a
lookahead. Suggested, in order: FIRST-set prefiltering of `CHOICE`
alternatives (already on the roadmap), merging a choice of literal or
keyword alternatives into one regex or trie, and documenting that
`compile_grammar` output can be saved. These speeds suit queries,
filters and configuration-sized programs, not large batches.

### 11. jq 1.8 as the host interpreter

Everything here was run with jq 1.7 as the interpreter: the grammars parse
the jq 1.8 *language*, but the library itself has not yet been tested
running under jq 1.8.

## Grammar notes

### SPARQL 1.1 ([`grammars/src/sparql11.jq`](../grammars/src/sparql11.jq))

- The rules are the 173 productions of SPARQL 1.1 Query §19.8 with the
  spec's names: `SelectClause`, `TriplesBlock`, `PathSequence`, …. Pure
  pass-through productions are hidden (`_iri`, `_VarOrTerm`, `_Expression`,
  …), and expression and path levels make a node only when an operator is
  present.
- Start rules: `QueryUnit` (default) and `UpdateUnit`.
- Built-in calls are one `BuiltInCall` node with a `name` field.
  Aggregates have `name`, `modifier` (`DISTINCT`) and `separator` fields.
- Numeric literals are one `NumericLiteral` token, sign included.

### jq 1.8 ([`grammars/src/jq.jq`](../grammars/src/jq.jq))

- The rules follow `parser.y` / `lexer.l` of jq 1.8.0, including the 1.8
  changes: the new precedence of `… as $x | …`, any `Expr` as an object
  value, and Tcl-style comment continuation with `\`.
- Node types: `program`, `module`, `import`, `function_definition`,
  `local_definition` (a `def` followed by its scope), `binding`, `label`,
  `pipe`, `comma`, the binary levels, `negation`, `try`, `reduce`,
  `foreach`, `if` / `elif` / `else`, `suffixed` (a term with `field`,
  `string_field`, `index`, `slice`, `iterate`, `optional` suffixes),
  `call`, `variable`, `string` (with `string_content`, `escape_sequence`,
  `interpolation`, and an optional `format`), `object` / `pair`, and
  destructuring patterns.
- The private `$$$$name` syntax of `builtin.jq` is supported
  (`private_variable`).
