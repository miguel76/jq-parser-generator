# Prior art and design decisions

This survey was done before writing the library, to check whether something
similar already existed and to choose a grammar representation.

## Parsing libraries in or for jq

| project | what it is | applicability |
|---------|------------|---------------|
| [jq wiki: Parsing Expression Grammars](https://github.com/jqlang/jq/wiki/Parsing-Expression-Grammars) | Shows that jq's own operators map onto PEG operators (`,`/`//`/`?`/`recurse`), with hand-written example parsers: balanced brackets, aⁿbⁿcⁿ, arithmetic, CSV. | A *technique*: each grammar is transcribed by hand into jq code. No grammar-as-data, no AST conventions, no streaming. |
| [Rosetta Code `peg.jq`](https://rosettacode.org/wiki/Category:Jq/peg.jq) | A small MIT-licensed module of PEG combinators (`star`, `plus`, `optional`, `parseNumber`, …) that thread `{remainder, result}` objects. | The closest existing library, but it is a combinator library: grammars are jq programs, not JSON data. Each step works on string remainders, which jq copies, so it is O(n²). No error reporting and no memoisation. |
| jq's own `fromjson`, `@csv`, `@tsv`, `splits`, `capture`, `scan` | Built-in fixed-format parsers and regex helpers. | Fixed formats only. |
| [micro-jq](https://github.com/elastic/micro-jq), gojq, jaq, jackson-jq | Parsers *of* the jq language, written in other languages. | Not relevant: they parse jq rather than running in it. |

**Conclusion:** no jq-native library parses with a grammar supplied as JSON,
so this project builds one. The jq wiki and `peg.jq` confirm that PEG is the
natural fit for jq's backtracking semantics. This library goes further: it
interprets grammars as data, uses codepoint-indexed matching to stay linear,
memoises, reports errors and streams.

## Grammar representations

| representation | JSON? | notes |
|----------------|-------|-------|
| **tree-sitter `grammar.json`** | **yes** (with a JSON Schema) | The de-facto JSON grammar format. Hundreds of grammars exist, generated from `grammar.js` by `tree-sitter generate`. A small set of composable node types (`SEQ`, `CHOICE`, `REPEAT`, `SYMBOL`, `STRING`, `PATTERN`, `FIELD`, `ALIAS`, `TOKEN`, `PREC*`). Includes the concepts an AST consumer needs: fields, aliases, hidden rules, extras. **Chosen.** |
| TextMate grammars (`.tmLanguage.json`) | yes | Regex-based tokenisers for syntax highlighting. They do not describe a syntax tree. |
| Chevrotain serialized GAST | yes | Internal JSON for one JS library's grammar AST. Not a widely used interchange format. |
| Ohm / peggy / PEG.js grammar ASTs | can be serialised | Tool-specific. Their textual PEG source maps 1:1 onto the chosen format, which has PEG extensions `AND`/`NOT`. |
| ISO/IEC 14977 EBNF, W3C EBNF (the XML-spec notation), ABNF (RFC 5234) | no (text) | Standard *notations* for context-free grammars, convertible to JSON (see [grammar-format.md](grammar-format.md#converting-other-grammar-notations)). They specify no AST shape. |
| ANTLR4 `.g4`, Lark `.lark`, Bison/Yacc | no (text) | Tool-specific. Often left-recursive, which a PEG cannot take without rewriting. |
| llama.cpp GBNF, Lezer, pest | no (text) | Tool-specific. |

The tree-sitter format won because it is JSON, has a schema and many real
grammars, and its AST model (named vs anonymous nodes, fields, hidden `_rules`)
suits jq consumers. An S-expression renderer (`to_sexp`) produces output in
tree-sitter's own test-corpus notation, so results can be compared directly.

### Deviations from tree-sitter

tree-sitter is GLR (generalized LR) with precedence annotations and a
context-aware lexer. This library interprets the grammar as a PEG instead
(ordered choice, greedy repetition, no left recursion, PREC ignored). Many
grammars work unchanged; the bundled tree-sitter-json grammar is one. Grammars
for expression languages, which rely on left recursion plus `PREC_LEFT` /
`PREC_RIGHT`, have to be restructured. Possible future work: precedence
climbing for left-recursive rules wrapped in `PREC_LEFT`/`PREC_RIGHT`, which
would let most tree-sitter grammars load unchanged.

## Implementation choices driven by jq's cost model

All of these were measured. See CLAUDE.md for the rules they imply.

- **No string slicing in the hot path.** In jq 1.7 and 1.8, `$s[i:]` is O(i) (UTF-8
  walking) and copies the slice. A substring-based parser is O(n²): about
  9 s for 20k slices of a 120 KB string. The input is therefore exploded
  once into a codepoint array. Literals are compared as array slices, and
  regexes run on a bounded window built from pre-imploded blocks: 2×`window`
  codepoints, re-tried on the full remainder only when a match reaches the
  end of the window.
- **Linear state threading.** jq values are copy-on-write. The parser state
  (position, memo table, children) is threaded through every function, and
  any extra live reference to it turns each memo write into a full copy.
  Snapshots therefore only capture the scalar fields they need, and `a // b`
  is not used on the state: a truthy `a` keeps a backtracking point alive,
  which pins the state.
- **Children as a persistent cons list** `[node, rest, length]`: O(1) push
  and O(1) snapshot/restore. Appending to arrays was quadratic for wide
  nodes.
- **Streaming finality by "touch" tracking**, plus geometric back-off when
  an incomplete record spans many chunks.
