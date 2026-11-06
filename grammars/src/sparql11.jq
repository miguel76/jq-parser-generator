# SPARQL 1.1 Query + Update grammar for jq-parser-generator.
#
# Transcribed from the W3C SPARQL 1.1 Query Language recommendation,
# section 19.8 "Grammar" (productions [1]-[173]). Production names are kept,
# so a node `(SelectClause ...)` corresponds to production [9].
#
# Generate the JSON grammar with:
#   jq -n -L . -f grammars/src/sparql11.jq > grammars/sparql11.json
#
# Start rules: `QueryUnit` (default) and `UpdateUnit` ({start: "UpdateUnit"}).
#
# What the grammar does NOT check (these are static semantics, not
# context-free syntax, see docs/sparql-and-jq.md): blank node label reuse
# across basic graph patterns and update operations, variable scoping of
# BIND / SELECT expressions / GROUP BY, duplicate projections, VALUES arity.
#
# The \u / \U escape pre-processing of SPARQL 1.1 §19.2 (which applies to
# the whole query text) is approximated the way SPARQL 1.2 does it: UCHAR
# escapes are accepted inside IRIREFs and string literals only.

include "jq-parser-generator";

# ---------------------------------------------------------------- helpers

# Characters that may continue a keyword-looking word. A keyword must not be
# followed by one of them, otherwise `selectx` or `select:x` would start with
# the keyword SELECT. (tree-sitter does this with `word`; the library ignores
# `word`, so every keyword carries its own lookahead.)
def _wordchar: "[A-Za-z0-9_:\\-\\x{00B7}\\x{00C0}-\\x{EFFFF}]";

# Case-insensitive keyword. Keyword literals are case-insensitive in SPARQL
# (except `a`); STRING is case-sensitive, so a PATTERN with the `i` flag is
# used instead.
# Multi-word keywords (`INSERT DATA`, `NOT IN`) allow whitespace and comments
# between the words.
def kw($k): pat("(?:" + ($k | gsub(" "; "(?:\\s|#[^\\r\\n]*)+")) + ")(?!" + _wordchar + ")"; "i");

def opt($r): optional($r);
def s($n): sym($n);

# A binary-operator level that produces a node only when an operator is
# actually present, so `?x` does not become a 10-level-deep chain of
# expression nodes. Returns two rules: `_<name>` (hidden) and `<name>`.
def level($name; $operand; $tail):
  { ("_" + $name): choice([s($name), s($operand)]),
    ($name): seq([s($operand), repeat1($tail)]) };

# Regex fragments for the terminals ([164]-[173])
def _PN_CHARS_BASE: "[A-Za-z\\x{00C0}-\\x{00D6}\\x{00D8}-\\x{00F6}\\x{00F8}-\\x{02FF}\\x{0370}-\\x{037D}\\x{037F}-\\x{1FFF}\\x{200C}-\\x{200D}\\x{2070}-\\x{218F}\\x{2C00}-\\x{2FEF}\\x{3001}-\\x{D7FF}\\x{F900}-\\x{FDCF}\\x{FDF0}-\\x{FFFD}\\x{10000}-\\x{EFFFF}]";
def _PN_CHARS_U: "(?:" + _PN_CHARS_BASE + "|_)";
def _PN_CHARS: "(?:" + _PN_CHARS_U + "|[-0-9\\x{00B7}\\x{0300}-\\x{036F}\\x{203F}-\\x{2040}])";
def _VARNAME: "(?:" + _PN_CHARS_U + "|[0-9])(?:" + _PN_CHARS_U + "|[0-9\\x{00B7}\\x{0300}-\\x{036F}\\x{203F}-\\x{2040}])*";
def _PN_PREFIX: "(?:" + _PN_CHARS_BASE + "(?:(?:" + _PN_CHARS + "|\\.)*" + _PN_CHARS + ")?)";
def _PLX: "(?:%[0-9A-Fa-f]{2}|\\\\[_~.\\-!$&'()*+,;=/?#@%])";
def _PN_LOCAL: "(?:(?:" + _PN_CHARS_U + "|:|[0-9]|" + _PLX + ")(?:(?:" + _PN_CHARS + "|\\.|:|" + _PLX + ")*(?:" + _PN_CHARS + "|:|" + _PLX + "))?)";
# UCHAR escapes must denote a Unicode scalar value (no surrogates, <= 10FFFF)
def _UCHAR: "\\\\u(?![dD][89a-fA-F])[0-9A-Fa-f]{4}|\\\\U(?:000(?!0[dD][89a-fA-F])[0-9A-Fa-f]{5}|0010[0-9A-Fa-f]{4})";
def _ECHAR: "\\\\[tbnrf\\\\\"']|" + _UCHAR;
def _IRICHARS: "(?:[^<>\"{}|^`\\\\\\x00-\\x20]|" + _UCHAR + ")*";

# `<` / `<=` are operators only when they do not start an IRIREF: SPARQL is
# tokenized with longest match, so `?x<?a&&?b>?y` contains the IRI
# `<?a&&?b>` and is a syntax error. A PEG has no tokenizer, so the
# longest-match rule is emulated with a lookahead.
def lt($op): pat($op + "(?!" + _IRICHARS + ">)");

# The triple templates of SPARQL Update come in variants: INSERT DATA and
# DELETE DATA forbid variables, DELETE templates forbid blank nodes (spec
# §19.6 notes 8-9). The library has no parametric rules, so the template
# rules are generated once per variant with a suffix, and ALIASed back to
# their base name so that the AST does not show the suffix.
def template_rules($sfx; $vars; $bnodes):
  def r($n): if $sfx == "" then s($n) elif ($n | startswith("_")) then s($n + $sfx) else alias(s($n + $sfx); $n) end;
  { QuadPattern: seq(["{", r("_Quads"), "}"]),
    QuadData: seq(["{", r("_Quads"), "}"]),
    _Quads: seq([opt(r("TriplesTemplate")), repeat(seq([r("QuadsNotTriples"), opt("."), opt(r("TriplesTemplate"))]))]),
    QuadsNotTriples: seq([kw("GRAPH"), r("_VarOrIri"), "{", opt(r("TriplesTemplate")), "}"]),
    TriplesTemplate: seq([r("TriplesSameSubject"), repeat(seq([".", r("TriplesSameSubject")])), opt(".")]),
    TriplesSameSubject: choice([seq([r("_VarOrTerm"), r("PropertyListNotEmpty")])]
                               + (if $bnodes then [seq([r("_TriplesNode"), opt(r("PropertyListNotEmpty"))])] else [] end)),
    PropertyListNotEmpty: seq([r("_Verb"), r("ObjectList"),
                               repeat(seq([";", opt(seq([r("_Verb"), r("ObjectList")]))]))]),
    _Verb: choice([r("_VarOrIri"), s("a")]),
    ObjectList: sep1(r("_GraphNode"); ","),
    _TriplesNode: choice([r("Collection"), r("BlankNodePropertyList")]),
    BlankNodePropertyList: seq(["[", r("PropertyListNotEmpty"), "]"]),
    Collection: seq(["(", repeat1(r("_GraphNode")), ")"]),
    _GraphNode: (if $bnodes then choice([r("_VarOrTerm"), r("_TriplesNode")]) else r("_VarOrTerm") end),
    _VarOrTerm: (if $vars then choice([s("Var"), r("_GraphTerm")]) else r("_GraphTerm") end),
    _VarOrIri: (if $vars then choice([s("Var"), s("_iri")]) else s("_iri") end),
    _GraphTerm: choice([s("_iri"), s("RDFLiteral"), s("_NumericLiteral"), s("BooleanLiteral")]
                       + (if $bnodes then [s("_BlankNode")] else [] end) + [s("NIL")])
  }
  | with_entries(.key += $sfx);

# ------------------------------------------------------------------ rules

def rules: {
  # [1]-[3]
  QueryUnit: s("Query"),
  Query: seq([s("_Prologue"),
              choice([s("SelectQuery"), s("ConstructQuery"), s("DescribeQuery"), s("AskQuery")]),
              s("_ValuesClause")]),
  UpdateUnit: s("_Update"),

  # [4]-[6]
  _Prologue: repeat(choice([s("BaseDecl"), s("PrefixDecl")])),
  BaseDecl: seq([kw("BASE"), s("IRIREF")]),
  PrefixDecl: seq([kw("PREFIX"), s("PNAME_NS"), s("IRIREF")]),

  # [7]-[12]
  SelectQuery: seq([s("SelectClause"), repeat(s("DatasetClause")), s("WhereClause"), s("_SolutionModifier")]),
  SubSelect: seq([s("SelectClause"), s("WhereClause"), s("_SolutionModifier"), s("_ValuesClause")]),
  SelectClause: seq([kw("SELECT"), opt(choice([field("modifier"; kw("DISTINCT")), field("modifier"; kw("REDUCED"))])),
                     choice([repeat1(choice([s("Var"), s("SelectExpression")])), field("star"; str("*"))])]),
  SelectExpression: seq(["(", s("_Expression"), kw("AS"), s("Var"), ")"]),
  ConstructQuery: seq([kw("CONSTRUCT"),
    choice([
      seq([s("ConstructTemplate"), repeat(s("DatasetClause")), s("WhereClause"), s("_SolutionModifier")]),
      seq([repeat(s("DatasetClause")), kw("WHERE"), "{", opt(s("TriplesTemplate")), "}", s("_SolutionModifier")])
    ])]),
  DescribeQuery: seq([kw("DESCRIBE"), choice([repeat1(s("_VarOrIri")), field("star"; str("*"))]),
                      repeat(s("DatasetClause")), opt(s("WhereClause")), s("_SolutionModifier")]),
  AskQuery: seq([kw("ASK"), repeat(s("DatasetClause")), s("WhereClause"), s("_SolutionModifier")]),

  # [13]-[17]
  DatasetClause: seq([kw("FROM"), choice([s("NamedGraphClause"), s("DefaultGraphClause")])]),
  DefaultGraphClause: s("_iri"),
  NamedGraphClause: seq([kw("NAMED"), s("_iri")]),
  WhereClause: seq([opt(kw("WHERE")), s("GroupGraphPattern")]),

  # [18]-[28]
  _SolutionModifier: seq([opt(s("GroupClause")), opt(s("HavingClause")), opt(s("OrderClause")), opt(s("LimitOffsetClauses"))]),
  GroupClause: seq([kw("GROUP"), kw("BY"), repeat1(s("GroupCondition"))]),
  GroupCondition: choice([s("_BuiltInCall"), s("FunctionCall"),
                          seq(["(", s("_Expression"), opt(seq([kw("AS"), s("Var")])), ")"]), s("Var")]),
  HavingClause: seq([kw("HAVING"), repeat1(s("_Constraint"))]),
  OrderClause: seq([kw("ORDER"), kw("BY"), repeat1(s("OrderCondition"))]),
  OrderCondition: choice([seq([field("direction"; choice([kw("ASC"), kw("DESC")])), s("BrackettedExpression")]),
                          s("_Constraint"), s("Var")]),
  LimitOffsetClauses: choice([seq([s("LimitClause"), opt(s("OffsetClause"))]),
                              seq([s("OffsetClause"), opt(s("LimitClause"))])]),
  LimitClause: seq([kw("LIMIT"), s("INTEGER")]),
  OffsetClause: seq([kw("OFFSET"), s("INTEGER")]),
  _ValuesClause: opt(s("InlineData")),

  # [29]-[49]  Update
  _Update: seq([s("_Prologue"), opt(seq([s("_Update1"), opt(seq([";", s("_Update")]))]))]),
  _Update1: choice([s("Load"), s("Clear"), s("Drop"), s("Add"), s("Move"), s("Copy"), s("Create"),
                    s("InsertData"), s("DeleteData"), s("DeleteWhere"), s("Modify")]),
  Load: seq([kw("LOAD"), opt(s("SILENT")), s("_iri"), opt(seq([kw("INTO"), s("GraphRef")]))]),
  Clear: seq([kw("CLEAR"), opt(s("SILENT")), s("GraphRefAll")]),
  Drop: seq([kw("DROP"), opt(s("SILENT")), s("GraphRefAll")]),
  Create: seq([kw("CREATE"), opt(s("SILENT")), s("GraphRef")]),
  Add: seq([kw("ADD"), opt(s("SILENT")), s("GraphOrDefault"), kw("TO"), s("GraphOrDefault")]),
  Move: seq([kw("MOVE"), opt(s("SILENT")), s("GraphOrDefault"), kw("TO"), s("GraphOrDefault")]),
  Copy: seq([kw("COPY"), opt(s("SILENT")), s("GraphOrDefault"), kw("TO"), s("GraphOrDefault")]),
  SILENT: kw("SILENT"),
  InsertData: seq([kw("INSERT DATA"), alias(s("QuadData_nv"); "QuadData")]),
  DeleteData: seq([kw("DELETE DATA"), alias(s("QuadData_nvb"); "QuadData")]),
  DeleteWhere: seq([kw("DELETE WHERE"), alias(s("QuadPattern_nb"); "QuadPattern")]),
  Modify: seq([opt(seq([kw("WITH"), s("_iri")])),
               choice([seq([s("DeleteClause"), opt(s("InsertClause"))]), s("InsertClause")]),
               repeat(s("UsingClause")), kw("WHERE"), s("GroupGraphPattern")]),
  DeleteClause: seq([kw("DELETE"), alias(s("QuadPattern_nb"); "QuadPattern")]),
  InsertClause: seq([kw("INSERT"), s("QuadPattern")]),
  UsingClause: seq([kw("USING"), choice([s("_iri"), seq([field("named"; kw("NAMED")), s("_iri")])])]),
  GraphOrDefault: choice([field("default"; kw("DEFAULT")), seq([opt(kw("GRAPH")), s("_iri")])]),
  GraphRef: seq([kw("GRAPH"), s("_iri")]),
  GraphRefAll: choice([s("GraphRef"), field("target"; kw("DEFAULT")), field("target"; kw("NAMED")), field("target"; kw("ALL"))]),

  # [53]-[68] graph patterns
  GroupGraphPattern: seq(["{", choice([s("SubSelect"), s("_GroupGraphPatternSub")]), "}"]),
  _GroupGraphPatternSub: seq([opt(s("TriplesBlock")),
                             repeat(seq([s("_GraphPatternNotTriples"), opt("."), opt(s("TriplesBlock"))]))]),
  TriplesBlock: seq([s("TriplesSameSubjectPath"), repeat(seq([".", s("TriplesSameSubjectPath")])), opt(".")]),
  _GraphPatternNotTriples: choice([s("GroupOrUnionGraphPattern"), s("OptionalGraphPattern"), s("MinusGraphPattern"),
                                   s("GraphGraphPattern"), s("ServiceGraphPattern"), s("Filter"), s("Bind"), s("InlineData")]),
  OptionalGraphPattern: seq([kw("OPTIONAL"), s("GroupGraphPattern")]),
  GraphGraphPattern: seq([kw("GRAPH"), s("_VarOrIri"), s("GroupGraphPattern")]),
  ServiceGraphPattern: seq([kw("SERVICE"), opt(s("SILENT")), s("_VarOrIri"), s("GroupGraphPattern")]),
  Bind: seq([kw("BIND"), "(", s("_Expression"), kw("AS"), s("Var"), ")"]),
  InlineData: seq([kw("VALUES"), s("_DataBlock")]),
  _DataBlock: choice([s("InlineDataOneVar"), s("InlineDataFull")]),
  InlineDataOneVar: seq([s("Var"), "{", repeat(s("_DataBlockValue")), "}"]),
  InlineDataFull: seq([choice([s("NIL"), seq(["(", repeat(s("Var")), ")"])]),
                       "{", repeat(choice([s("DataBlockRow"), s("NIL")])), "}"]),
  DataBlockRow: seq(["(", repeat(s("_DataBlockValue")), ")"]),
  _DataBlockValue: choice([s("_iri"), s("RDFLiteral"), s("_NumericLiteral"), s("BooleanLiteral"), s("UNDEF")]),
  UNDEF: kw("UNDEF"),
  MinusGraphPattern: seq([kw("MINUS"), s("GroupGraphPattern")]),
  GroupOrUnionGraphPattern: seq([s("GroupGraphPattern"), repeat(seq([kw("UNION"), s("GroupGraphPattern")]))]),
  Filter: seq([kw("FILTER"), s("_Constraint")]),
  _Constraint: choice([s("BrackettedExpression"), s("_BuiltInCall"), s("FunctionCall")]),
  FunctionCall: seq([s("_iri"), s("ArgList")]),
  ArgList: choice([s("NIL"), seq(["(", opt(field("modifier"; kw("DISTINCT"))), sep1(s("_Expression"); ","), ")"])]),
  ExpressionList: choice([s("NIL"), seq(["(", sep1(s("_Expression"); ","), ")"])]),

  # [73]-[109] triples
  ConstructTemplate: seq(["{", opt(s("TriplesTemplate")), "}"]),
  a: pat("a(?!" + _wordchar + ")"),
  TriplesSameSubjectPath: choice([seq([s("_VarOrTerm"), s("PropertyListPathNotEmpty")]),
                                  seq([s("_TriplesNodePath"), opt(s("PropertyListPathNotEmpty"))])]),
  PropertyListPathNotEmpty: seq([choice([s("_Path"), s("Var")]), s("ObjectListPath"),
                                 repeat(seq([";", opt(seq([choice([s("_Path"), s("Var")]), s("ObjectList")]))]))]),
  ObjectListPath: sep1(s("_GraphNodePath"); ","),

  # [88]-[96] property paths
  _Path: s("_PathAlternative"),
  PathPrimary: choice([s("_iri"), s("a"), seq(["!", s("PathNegatedPropertySet")]), seq(["(", s("_Path"), ")"])]),
  PathElt: seq([s("PathPrimary"), opt(s("PathMod"))]),
  # `?` followed by a name is a variable, not a path modifier (tokenizer longest match)
  PathMod: choice([seq(["?", not_followed_by(immediate_token(pat("[A-Za-z0-9_\\x{00C0}-\\x{EFFFF}]")))]), "*", "+"]),
  _PathEltOrInverse: choice([s("PathElt"), s("PathInverse")]),
  PathInverse: seq(["^", s("PathElt")]),
  PathNegatedPropertySet: choice([s("_PathOneInPropertySet"),
                                  seq(["(", opt(sep1(s("_PathOneInPropertySet"); "|")), ")"])]),
  _PathOneInPropertySet: choice([s("_iri"), s("a"), s("PathInverseOne")]),
  PathInverseOne: seq(["^", choice([s("_iri"), s("a")])]),

  _TriplesNodePath: choice([s("CollectionPath"), s("BlankNodePropertyListPath")]),
  BlankNodePropertyListPath: seq(["[", s("PropertyListPathNotEmpty"), "]"]),
  CollectionPath: seq(["(", repeat1(s("_GraphNodePath")), ")"]),
  _GraphNodePath: choice([s("_VarOrTerm"), s("_TriplesNodePath")]),
  Var: choice([s("VAR1"), s("VAR2")]),

  # [110]-[120] expressions
  _Expression: s("_ConditionalOrExpression"),
  _ValueLogical: s("_RelationalExpression"),
  _RelationalExpression: choice([s("RelationalExpression"), s("_AdditiveExpression")]),
  RelationalExpression: seq([s("_AdditiveExpression"),
    choice([seq([field("operator"; choice(["=", "!=", lt("<="), ">=", lt("<"), ">"])), s("_AdditiveExpression")]),
            seq([field("operator"; kw("IN")), s("ExpressionList")]),
            seq([field("operator"; kw("NOT\\s+IN")), s("ExpressionList")])])]),
  UnaryExpression: seq([field("operator"; choice(["!", "+", "-"])), s("_PrimaryExpression")]),
  _UnaryExpression: choice([s("UnaryExpression"), s("_PrimaryExpression")]),
  _PrimaryExpression: choice([s("BrackettedExpression"), s("_BuiltInCall"), s("_iriOrFunction"), s("RDFLiteral"),
                              s("_NumericLiteral"), s("BooleanLiteral"), s("Var")]),
  BrackettedExpression: seq(["(", s("_Expression"), ")"]),

  # [121]-[127] built-in calls. Generic shape: name followed by an argument
  # list; arity is checked by the grammar as in the spec.
  _BuiltInCall: choice([s("Aggregate"), s("BuiltInCall"), s("ExistsFunc"), s("NotExistsFunc")]),
  BuiltInCall: choice(
      ([ "STR", "LANG", "DATATYPE", "IRI", "URI", "ABS", "CEIL", "FLOOR", "ROUND", "STRLEN", "UCASE",
         "LCASE", "ENCODE_FOR_URI", "YEAR", "MONTH", "DAY", "HOURS", "MINUTES", "SECONDS", "TIMEZONE",
         "TZ", "MD5", "SHA1", "SHA256", "SHA384", "SHA512", "isIRI", "isURI", "isBLANK", "isLITERAL",
         "isNUMERIC" ] | map(seq([field("name"; kw(.)), "(", s("_Expression"), ")"])))
    + ([ "LANGMATCHES", "CONTAINS", "STRSTARTS", "STRENDS", "STRBEFORE", "STRAFTER", "STRLANG", "STRDT",
         "sameTerm" ] | map(seq([field("name"; kw(.)), "(", s("_Expression"), ",", s("_Expression"), ")"])))
    + ([ "RAND", "NOW", "UUID", "STRUUID" ] | map(seq([field("name"; kw(.)), s("NIL")])))
    + [ seq([field("name"; kw("BOUND")), "(", s("Var"), ")"]),
        seq([field("name"; kw("BNODE")), choice([seq(["(", s("_Expression"), ")"]), s("NIL")])]),
        seq([field("name"; kw("CONCAT")), s("ExpressionList")]),
        seq([field("name"; kw("COALESCE")), s("ExpressionList")]),
        seq([field("name"; kw("IF")), "(", s("_Expression"), ",", s("_Expression"), ",", s("_Expression"), ")"]),
        seq([field("name"; kw("SUBSTR")), "(", s("_Expression"), ",", s("_Expression"), opt(seq([",", s("_Expression")])), ")"]),
        seq([field("name"; kw("REPLACE")), "(", s("_Expression"), ",", s("_Expression"), ",", s("_Expression"),
             opt(seq([",", s("_Expression")])), ")"]),
        seq([field("name"; kw("REGEX")), "(", s("_Expression"), ",", s("_Expression"), opt(seq([",", s("_Expression")])), ")"]) ]),
  ExistsFunc: seq([kw("EXISTS"), s("GroupGraphPattern")]),
  NotExistsFunc: seq([kw("NOT"), kw("EXISTS"), s("GroupGraphPattern")]),
  Aggregate: choice([
    seq([field("name"; kw("COUNT")), "(", opt(field("modifier"; kw("DISTINCT"))), choice([field("star"; str("*")), s("_Expression")]), ")"]),
    seq([field("name"; choice([kw("SUM"), kw("MIN"), kw("MAX"), kw("AVG"), kw("SAMPLE")])), "(",
         opt(field("modifier"; kw("DISTINCT"))), s("_Expression"), ")"]),
    seq([field("name"; kw("GROUP_CONCAT")), "(", opt(field("modifier"; kw("DISTINCT"))), s("_Expression"),
         opt(seq([";", kw("SEPARATOR"), "=", field("separator"; s("_String"))])), ")"])]),

  # [128]-[138] terms
  _iriOrFunction: choice([s("FunctionCall"), s("_iri")]),
  RDFLiteral: seq([s("_String"), opt(choice([s("LANGTAG"), seq(["^^", field("datatype"; s("_iri"))])]))]),
  _NumericLiteral: choice([s("NumericLiteral")]),
  # INTEGER/DECIMAL/DOUBLE and their signed forms as one token (longest match)
  NumericLiteral: token(seq([opt(pat("[+-]")),
                             choice([pat("[0-9]+\\.[0-9]*[eE][+-]?[0-9]+|\\.[0-9]+[eE][+-]?[0-9]+|[0-9]+[eE][+-]?[0-9]+"),
                                     pat("[0-9]*\\.[0-9]+"),
                                     pat("[0-9]+")])])),
  BooleanLiteral: choice([kw("true"), kw("false")]),
  _String: choice([s("STRING_LITERAL_LONG1"), s("STRING_LITERAL_LONG2"), s("STRING_LITERAL1"), s("STRING_LITERAL2")]),
  _iri: choice([s("IRIREF"), s("PrefixedName")]),
  PrefixedName: choice([s("PNAME_LN"), s("PNAME_NS")]),
  _BlankNode: choice([s("BLANK_NODE_LABEL"), s("ANON")]),

  # [139]-[173] terminals
  IRIREF: pat("<" + _IRICHARS + ">"),
  PNAME_NS: pat(_PN_PREFIX + "?:"),
  PNAME_LN: pat(_PN_PREFIX + "?:" + _PN_LOCAL),
  BLANK_NODE_LABEL: pat("_:(?:" + _PN_CHARS_U + "|[0-9])(?:(?:" + _PN_CHARS + "|\\.)*" + _PN_CHARS + ")?"),
  VAR1: pat("\\?" + _VARNAME),
  VAR2: pat("\\$" + _VARNAME),
  LANGTAG: pat("@[a-zA-Z]+(?:-[a-zA-Z0-9]+)*"),
  INTEGER: pat("[0-9]+"),
  STRING_LITERAL1: pat("'(?:[^\\x27\\x5C\\x0A\\x0D]|" + _ECHAR + ")*'"),
  STRING_LITERAL2: pat("\"(?:[^\\x22\\x5C\\x0A\\x0D]|" + _ECHAR + ")*\""),
  STRING_LITERAL_LONG1: pat("'''(?:(?:'|'')?(?:[^'\\\\]|" + _ECHAR + "))*'''"),
  STRING_LITERAL_LONG2: pat("\"\"\"(?:(?:\"|\"\")?(?:[^\"\\\\]|" + _ECHAR + "))*\"\"\""),
  NIL: pat("\\([\\x20\\x09\\x0D\\x0A]*\\)"),
  ANON: pat("\\[[\\x20\\x09\\x0D\\x0A]*\\]")
}
# Expression levels with "node only if an operator is present"
+ level("ConditionalOrExpression"; "_ConditionalAndExpression"; seq([field("operator"; "||"), s("_ConditionalAndExpression")]))
+ level("ConditionalAndExpression"; "_ValueLogical"; seq([field("operator"; "&&"), s("_ValueLogical")]))
+ level("AdditiveExpression"; "_MultiplicativeExpression";
        seq([field("operator"; choice(["+", "-"])), s("_MultiplicativeExpression")]))
+ level("MultiplicativeExpression"; "_UnaryExpression";
        seq([field("operator"; choice(["*", "/"])), s("_UnaryExpression")]))
+ template_rules(""; true; true)
+ template_rules("_nv"; false; true)
+ template_rules("_nb"; true; false)
+ template_rules("_nvb"; false; false)
+ level("PathAlternative"; "_PathSequence"; seq(["|", s("_PathSequence")]))
+ level("PathSequence"; "_PathEltOrInverse"; seq(["/", s("_PathEltOrInverse")]));

{
  name: "sparql11",
  start: "QueryUnit",
  rules: rules,
  extras: [pat("\\s"), pat("#[^\\r\\n]*")]
}
