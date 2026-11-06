# jq 1.8 grammar for jq-parser-generator.
#
# Transcribed from jq 1.8.0's src/parser.y (bison, LALR with %prec
# declarations) and src/lexer.l (flex). The bison grammar is left-recursive
# and relies on precedence declarations; a PEG supports neither, so every
# precedence level is a separate rule (see docs/sparql-and-jq.md).
#
# Generate the JSON grammar with:
#   jq -n -L . -f grammars/src/jq.jq > grammars/jq.json
#
# Operator precedence, lowest first (parser.y):
#   def ...; Q   E as $p | Q   label $l | Q      (extend as far right as possible)
#   |  (right)   ,  (left)   //  (right)
#   = |= += -= *= /= %= //=  (nonassoc)
#   or   and   == != < <= > >= (nonassoc)   + -   * / %
#   postfix: .foo  ."s"  [..]  .[..]  ?       prefix: -  try  reduce  foreach  if
#
# Binary levels produce a node only when an operator is present, and their
# operands are a flat list: `1 - 2 - 3` is (additive (number) "-" (number)
# "-" (number)), not a left-nested tree. Associativity is implied by the
# level (see the table above).

include "jq-parser-generator";

def s($n): sym($n);
def opt($r): optional($r);

# Identifier characters. A keyword must not be followed by one of them,
# otherwise `iffy` would start with the keyword `if` (flex picks the longest
# match). tree-sitter's `word` would do this; the library ignores `word`.
def _identcont: "[a-zA-Z0-9_]|::[a-zA-Z_]";
def kw($k): seq([str($k), not_followed_by(immediate_token(pat(_identcont)))]);

# An operator that must not be the prefix of a longer operator, e.g. `|`
# vs `|=` or `/` vs `//`. flex does this with longest match.
def op($o; $notnext): seq([str($o), not_followed_by(immediate_token(pat($notnext)))]);
def op($o): op($o; "=");

def keywords: ["as", "def", "module", "import", "include", "if", "then", "else", "elif",
               "reduce", "foreach", "end", "and", "or", "try", "catch", "label", "break"];
def _ident_re: "(?:[a-zA-Z_][a-zA-Z0-9_]*::)*[a-zA-Z_][a-zA-Z0-9_]*";

# A binary level: `_<name>` is hidden and is either `<name>` (with at least
# one operator) or the operand alone.
def level($name; $operand; $ops):
  { ("_" + $name): choice([s($name), s($operand)]),
    ($name): seq([s($operand), repeat1(seq([field("operator"; choice($ops)), s($operand)]))]) };
def nonassoc($name; $operand; $ops):
  { ("_" + $name): choice([s($name), s($operand)]),
    ($name): seq([s($operand), field("operator"; choice($ops)), s($operand)]) };

def rules: {
  # TopLevel: Module Imports Query | Module Imports FuncDefs
  program: seq([opt(s("module")), repeat(s("import")),
                choice([s("_query"), repeat(s("function_definition"))])]),
  module: seq([kw("module"), s("_query"), ";"]),
  import: seq([choice([seq([kw("import"), field("path"; s("string")), kw("as"),
                            field("name"; choice([s("variable"), s("identifier")]))]),
                       seq([kw("include"), field("path"; s("string"))])]),
               opt(field("metadata"; s("_query"))), ";"]),

  function_definition: seq([kw("def"), field("name"; s("identifier")),
                            opt(seq(["(", sep1(field("parameter"; choice([s("variable"), s("identifier")])); ";"), ")"])),
                            ":", field("body"; s("_query")), ";"]),

  # ---- Query level: forms that extend as far right as possible, `|`, `,`
  _query: choice([s("_scoped"), s("pipe"), s("_comma_level")]),
  _scoped: choice([s("local_definition"), s("binding"), s("label")]),
  local_definition: seq([s("function_definition"), field("body"; s("_query"))]),
  binding: seq([field("source"; s("_expression")), kw("as"), s("_patterns"), op("|"), field("body"; s("_query"))]),
  label: seq([kw("label"), field("name"; s("variable")), op("|"), field("body"; s("_query"))]),
  pipe: seq([s("_comma_level"), repeat1(seq([op("|"), choice([s("_scoped"), s("_comma_level")])]))]),
  _comma_level: choice([s("comma"), s("_expression")]),
  comma: seq([s("_expression"), repeat1(seq([",", choice([s("_scoped"), s("_expression")])]))]),

  # ---- Expr levels
  _expression: s("_alternative"),

  # ---- Terms: a primary followed by postfix suffixes
  _postfix_term: choice([s("negation"), s("suffixed"), s("_primary")]),
  negation: seq([op("-"), s("_postfix_term")]),
  suffixed: seq([s("_primary"), repeat1(s("_suffix"))]),
  _suffix: choice([
    s("optional"),
    alias(s("field_access"); "field"),
    s("string_field"),
    s("index"), s("iterate"), s("slice")]),
  # `?//` is one token (destructuring alternative), so `.a?//1` is an error in jq
  optional: op("?"; "//"),
  field_access: pat("\\.[a-zA-Z_][a-zA-Z0-9_]*"),
  index: seq([opt("."), "[", s("_query"), "]"]),
  iterate: seq([opt("."), "[", "]"]),
  slice: seq(["[", choice([seq([field("from"; s("_query")), ":", opt(field("to"; s("_query")))]),
                           seq([":", field("to"; s("_query"))])]), "]"]),

  _primary: choice([
    s("number"), s("string"), s("format"),
    s("recurse"),
    alias(s("field_access"); "field"),
    s("string_field"),
    s("identity"),
    s("parenthesized"), s("array"), s("object"),
    s("reduce"), s("foreach"), s("if"), s("try"),
    s("break"),
    s("loc"), s("variable"), s("private_variable"),
    s("call")]),

  # `."foo"` (also `. "foo"`, they are two tokens)
  string_field: seq([".", s("string")]),
  identity: pat("\\.(?![.0-9a-zA-Z_])"),
  recurse: str(".."),
  number: pat("(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?"),
  format: pat("@[a-zA-Z0-9_]+"),
  parenthesized: seq(["(", s("_query"), ")"]),
  array: seq(["[", opt(s("_query")), "]"]),
  object: seq(["{", opt(seq([sep1(s("pair"); ","), opt(",")])), "}"]),
  pair: choice([
    seq([field("key"; choice([s("object_key"), s("string"), s("variable"),
                              seq(["(", s("_query"), ")"])])),
         ":", field("value"; s("_object_value"))]),
    field("key"; choice([s("object_key"), s("string"), s("variable"), s("loc")]))]),
  object_key: pat(_ident_re),
  _object_value: choice([s("object_value_pipe"), s("_expression")]),
  object_value_pipe: seq([s("_expression"), repeat1(seq([op("|"), s("_expression")]))]),

  reduce: seq([kw("reduce"), field("source"; s("_expression")), kw("as"), s("_patterns"),
               "(", field("init"; s("_query")), ";", field("update"; s("_query")), ")"]),
  foreach: seq([kw("foreach"), field("source"; s("_expression")), kw("as"), s("_patterns"),
                "(", field("init"; s("_query")), ";", field("update"; s("_query")),
                opt(seq([";", field("extract"; s("_query"))])), ")"]),
  if: seq([kw("if"), field("condition"; s("_query")), kw("then"), field("consequence"; s("_query")),
           repeat(s("elif")), opt(s("else")), kw("end")]),
  elif: seq([kw("elif"), field("condition"; s("_query")), kw("then"), field("consequence"; s("_query"))]),
  else: seq([kw("else"), s("_query")]),
  # try/catch bind tighter than every operator: the body is a postfix term
  try: seq([kw("try"), field("body"; s("_postfix_term")),
            opt(seq([kw("catch"), field("handler"; s("_postfix_term"))]))]),
  break: seq([kw("break"), s("variable")]),

  loc: pat("\\$__loc__(?![a-zA-Z0-9_])"),
  variable: pat("\\$(?!__loc__(?![a-zA-Z0-9_]|::[a-zA-Z_]))" + _ident_re),
  # `$$$$name`: private to jq's builtins (parser.y)
  private_variable: seq(["$", "$", "$", s("variable")]),
  call: seq([field("name"; s("identifier")),
             opt(seq(["(", sep1(field("argument"; s("_query")); ";"), ")"]))]),
  identifier: pat("(?!(?:" + (keywords | join("|")) + ")(?!" + _identcont + "))" + _ident_re),

  # ---- destructuring patterns
  _patterns: seq([s("_pattern"), repeat(seq(["?//", s("_pattern")]))]),
  _pattern: choice([s("variable"), s("array_pattern"), s("object_pattern")]),
  array_pattern: seq(["[", sep1(s("_pattern"); ","), "]"]),
  object_pattern: seq(["{", sep1(s("pattern_pair"); ","), "}"]),
  pattern_pair: choice([
    seq([field("key"; choice([s("variable"), s("object_key"), s("string"), seq(["(", s("_query"), ")"])])),
         ":", field("value"; s("_pattern"))]),
    field("key"; s("variable"))]),

  # ---- strings. Inside the quotes nothing is skipped: every piece is an
  # IMMEDIATE_TOKEN, otherwise `"#x"` would be read as a comment.
  string: seq([opt(field("format"; s("format"))), "\"",
                repeat(choice([s("string_content"), s("escape_sequence"), s("interpolation")])),
                immediate_token("\"")]),
  string_content: immediate_token(pat("[^\\\\\"]+")),
  escape_sequence: immediate_token(pat("\\\\(?:[\"\\\\/bfnrt]|u[0-9a-fA-F]{4})")),
  interpolation: seq([immediate_token("\\("), s("_query"), ")"])
}
+ level("alternative"; "_assignment"; [op("//")])
+ nonassoc("assignment"; "_or"; [op("="), "|=", "+=", "-=", "*=", "/=", "%=", "//="])
+ level("or"; "_and"; [kw("or")])
+ level("and"; "_comparison"; [kw("and")])
+ nonassoc("comparison"; "_additive"; ["==", "!=", "<=", ">=", op("<"), op(">")])
+ level("additive"; "_multiplicative"; [op("+"), op("-")])
+ level("multiplicative"; "_postfix_term"; [op("*"), op("/"; "[/=]"), op("%")]);

{
  name: "jq",
  start: "program",
  rules: rules,
  extras: [
    pat("[ \\t\\r\\n]+"),
    # comments, with Tcl-style continuation: an odd number of backslashes
    # before the newline continues the comment (jq 1.8)
    pat("#(?:\\\\(?:\\\\|\\r?\\n)|\\r(?!\\n)|[^\\r\\n])*")
  ]
}
