# Grammar format reference

A grammar is a JSON object in the format of tree-sitter's `src/grammar.json`.
The JSON Schema for that format is
[`grammar.schema.json`](https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/assets/schemas/grammar.schema.json)
in the tree-sitter repository. This page describes how jq-parser-generator
interprets the format.

```json
{
  "name": "my_language",
  "rules":  { "<rule name>": <rule>, ... },
  "extras": [ <rule>, ... ]
}
```

| key      | used | notes |
|----------|------|-------|
| `name`   | informative | |
| `rules`  | **yes** | Order matters: the **first rule is the start rule** unless `start` is set in the grammar or in the options. Rule names starting with `_` are *hidden*. |
| `extras` | **yes** | Rules skipped before every terminal. Defaults to `[{"type": "PATTERN", "value": "\\s"}]`. Use `[]` for whitespace-sensitive languages. |
| `start`  | yes (extension) | Name of the start rule. |
| `word`, `conflicts`, `precedences`, `inline`, `supertypes`, `externals`, `reserved` | ignored | Accepted, so that tree-sitter grammars load unchanged. |

## Rules

| type | fields | PEG meaning | nodes produced |
|------|--------|-------------|----------------|
| `STRING` | `value` | Literal text. | none (anonymous when inside `FIELD`/`ALIAS`) |
| `PATTERN` | `value`, `flags`? | Regex (Oniguruma), anchored at the current position. Flags: `i`, `x`. | none |
| `SYMBOL` | `name` | Invoke a rule (memoised). | one node `{type: name}`, or its children if `name` starts with `_` |
| `SEQ` | `members` | All members, in order. | children of the members |
| `CHOICE` | `members` | **Ordered** choice: the first member that matches. Inside a token: the **longest** member. | those of the chosen member |
| `REPEAT` | `content` | Zero or more, greedy. | |
| `REPEAT1` | `content` | One or more, greedy. | |
| `BLANK` | | Matches the empty string. `CHOICE(x, BLANK)` = optional. | |
| `TOKEN` | `content` | Matches `content` as one lexical unit: no extras inside, longest-match choices, no child nodes. | none |
| `IMMEDIATE_TOKEN` | `content` | Like `TOKEN`, but without skipping extras *before* it. | none |
| `FIELD` | `name`, `content` | Tags the nodes produced by `content` with `"field": name`. If `content` produces no node, an anonymous leaf is created, e.g. `operator: "+"`. | |
| `ALIAS` | `value`, `named`, `content` | Renames the node produced by `content` (when it is a `SYMBOL`), or wraps the match in a node `{type: value}`. With `named: false` the node is anonymous. | |
| `PREC`, `PREC_LEFT`, `PREC_RIGHT`, `PREC_DYNAMIC` | `value`, `content` | Ignored, the same as `content`. | |
| `RESERVED` | `context_name`, `content` | Ignored, the same as `content`. | |
| `EOF` | | Matches only at the end of the whole input. | |
| `AND` *(extension)* | `content` | Positive lookahead `&e`: succeeds if `content` matches, consumes nothing. | none |
| `NOT` *(extension)* | `content` | Negative lookahead `!e`. | none |

Shorthands accepted wherever a rule is expected:

- `"text"` is the same as `{"type": "STRING", "value": "text"}`.
- `[r1, r2]` is the same as `{"type": "SEQ", "members": [r1, r2]}`.

Like all rules, `AND` and `NOT` skip extras before looking. To test the very
next character, wrap the content in `IMMEDIATE_TOKEN`, as in
`seq("if", not_followed_by(immediate_token(pat("[a-z]"))))`.

## jq DSL

`include "jq-parser-generator";` (or `import ... as P;` and prefix the names
with `P::`) provides constructors named after tree-sitter's `grammar.js`
helpers:

```
blank  eof  str($s)  pat($re)  pat($re; $flags)  sym($name)
seq($members)  choice($members)  repeat($r)  repeat1($r)  optional($r)
token($r)  immediate_token($r)  field($name; $r)  alias($r; $name)  alias($r; $name; $named)
prec($n; $r)  prec_left($n; $r)  prec_right($n; $r)  prec_dynamic($n; $r)
followed_by($r)  not_followed_by($r)  sep1($r; $sep)  sep($r; $sep)
```

Note that the module's `repeat/1` shadows jq's builtin `repeat/1` inside
code that uses `include`.

## Converting other grammar notations

The tree-sitter JSON format is easy to generate from other notations:

| notation | conversion |
|----------|------------|
| PEG (Ford 2004), peggy / PEG.js, pest | `e1 e2` → `SEQ`, `e1 / e2` → `CHOICE`, `e*` / `e+` / `e?` → `REPEAT` / `REPEAT1` / `CHOICE(e, BLANK)`, `&e` / `!e` → `AND` / `NOT`, `"lit"` → `STRING`, `[a-z]` → `PATTERN`. Semantics are identical. |
| W3C EBNF (the XML-spec notation), ISO 14977 EBNF, ABNF (RFC 5234) | Same mapping. ABNF `n*m` repetitions unfold into `SEQ`/`CHOICE`. Alternatives may need reordering (longest first), because CFG alternation is unordered and PEG choice is ordered. |
| ANTLR4, Lark | Lexer rules → `TOKEN`/`PATTERN` rules. Parser rules → the mapping above. Left-recursive rules must be rewritten as repetitions. |
| tree-sitter `grammar.js` | Run `tree-sitter generate` and use the resulting `src/grammar.json`. |
