module {
  "name": "jq-parser-generator",
  "version": "0.1.0",
  "description": "A grammar-driven (PEG) lexer/parser written in pure jq. Grammars use the tree-sitter grammar.json format.",
  "homepage": "https://github.com/miguel76/jq-parser-generator",
  "license": "GPL-3.0"
};

# =============================================================================
# jq-parser-generator
#
# A scannerless, packrat-memoised PEG parser interpreter in pure jq.
#
# Grammars are JSON documents in the tree-sitter `grammar.json` format
# (https://tree-sitter.github.io/tree-sitter/ - see `src/grammar.json` in any
# tree-sitter grammar repository), interpreted with PEG semantics:
#   - CHOICE is ordered (first alternative that matches wins), except inside
#     TOKEN / IMMEDIATE_TOKEN where the longest alternative wins (lexer-like);
#   - REPEAT / REPEAT1 are greedy and never backtrack;
#   - PREC* and RESERVED wrappers are accepted and ignored.
# Two non-tree-sitter extensions are supported: AND (&e) and NOT (!e)
# syntactic predicates.
#
# Public API (see README.md for details):
#   parse($grammar), parse($grammar; $opts)   - parse the stream `., inputs`
#   parse_stream($grammar; $opts; chunks)      - parse an arbitrary stream of strings
#   parse_string($grammar), parse_string($grammar; $opts) - parse `.` (one string)
#   compile_grammar                            - validate & precompile a grammar
#   to_sexp, strip_positions, nodes            - AST utilities
#   seq, choice, repeat, ... (grammar builder DSL)
# =============================================================================


# -----------------------------------------------------------------------------
# Grammar builder DSL (mirrors tree-sitter's grammar.js helpers)
# -----------------------------------------------------------------------------

def blank: {type: "BLANK"};
def eof: {type: "EOF"};
def str($value): {type: "STRING", value: $value};
def pat($regex): {type: "PATTERN", value: $regex};
def pat($regex; $flags): {type: "PATTERN", value: $regex, flags: $flags};
def sym($name): {type: "SYMBOL", name: $name};
def seq($members): {type: "SEQ", members: $members};
def choice($members): {type: "CHOICE", members: $members};
def repeat($rule): {type: "REPEAT", content: $rule};
def repeat1($rule): {type: "REPEAT1", content: $rule};
def optional($rule): {type: "CHOICE", members: [$rule, {type: "BLANK"}]};
def token($rule): {type: "TOKEN", content: $rule};
def immediate_token($rule): {type: "IMMEDIATE_TOKEN", content: $rule};
def field($name; $rule): {type: "FIELD", name: $name, content: $rule};
def alias($rule; $value): {type: "ALIAS", value: $value, named: true, content: $rule};
def alias($rule; $value; $named): {type: "ALIAS", value: $value, named: $named, content: $rule};
def prec($value; $rule): {type: "PREC", value: $value, content: $rule};
def prec_left($value; $rule): {type: "PREC_LEFT", value: $value, content: $rule};
def prec_right($value; $rule): {type: "PREC_RIGHT", value: $value, content: $rule};
def prec_dynamic($value; $rule): {type: "PREC_DYNAMIC", value: $value, content: $rule};
# PEG syntactic predicates (extension, not part of tree-sitter)
def followed_by($rule): {type: "AND", content: $rule};
def not_followed_by($rule): {type: "NOT", content: $rule};
# Comma/separator helpers commonly defined in tree-sitter grammars
def sep1($rule; $sep): seq([$rule, repeat(seq([$sep, $rule]))]);
def sep($rule; $sep): optional(sep1($rule; $sep));


# -----------------------------------------------------------------------------
# Grammar compilation & validation
# -----------------------------------------------------------------------------

def _gerr($msg): error("jq-parser-generator: " + $msg);

# Normalise and annotate one rule.
#   $rn  - name of the enclosing grammar rule (for labels / messages)
#   $top - true when this node is the whole body of the rule (modulo PREC)
def _crule($rn; $top):
  if type == "string" then {type: "STRING", value: .} | _crule($rn; $top)
  elif type == "array" then {type: "SEQ", members: .} | _crule($rn; $top)
  elif type != "object" then _gerr("invalid rule in '\($rn)': \(tojson)")
  else
    .type as $t
    | if $t == "STRING" then
        if (.value | type) != "string" then _gerr("STRING without string value in '\($rn)'") else . end
        | .cps = (.value | explode) | .n = (.cps | length) | .label = (.value | tojson)
      elif $t == "PATTERN" then
        if (.value | type) != "string" then _gerr("PATTERN without string value in '\($rn)'") else . end
        | .re = "\\A(?:" + .value + ")"
        | .fl = ((.flags // "") | gsub("[^ix]"; ""))
        | .label = (if $top then $rn else "/" + .value + "/" end)
        | . as $p
        | (try ("" | test($p.re; $p.fl)) catch _gerr("invalid regex /\($p.value)/ in '\($rn)': \(.)")) as $_
        | .
      elif $t == "SEQ" or $t == "CHOICE" then
        if (.members | type) != "array" then _gerr("\($t) without members in '\($rn)'") else . end
        | .members |= map(_crule($rn; false))
      elif $t == "PREC" or $t == "PREC_LEFT" or $t == "PREC_RIGHT" or $t == "PREC_DYNAMIC" or $t == "RESERVED" then
        .content | _crule($rn; $top)
      elif $t == "TOKEN" or $t == "IMMEDIATE_TOKEN" then
        .content |= _crule($rn; false) | .label = (if $top then $rn else "token" end)
      elif $t == "REPEAT" or $t == "REPEAT1" or $t == "FIELD" or $t == "ALIAS" or $t == "AND" or $t == "NOT" then
        .content |= _crule($rn; false)
      elif $t == "SYMBOL" then
        if (.name | type) != "string" then _gerr("SYMBOL without name in '\($rn)'") else . end
      elif $t == "BLANK" or $t == "EOF" then .
      else _gerr("unsupported rule type '\($t)' in '\($rn)'")
      end
  end;

# Can the (compiled) rule match the empty string? $N: rule name -> bool
def _nullable($N):
  .type as $t
  | if $t == "STRING" then .n == 0
    elif $t == "PATTERN" then (. as $r | "" | test($r.re; $r.fl))
    elif $t == "SEQ" then all(.members[]; _nullable($N))
    elif $t == "CHOICE" then any(.members[]; _nullable($N))
    elif $t == "REPEAT" or $t == "BLANK" or $t == "EOF" or $t == "AND" or $t == "NOT" then true
    elif $t == "SYMBOL" then ($N[.name] // false)
    else .content | _nullable($N)
    end;

# Symbols that can be invoked at the very start position of the rule.
def _leftsyms($N):
  .type as $t
  | if $t == "SYMBOL" then [.name]
    elif $t == "SEQ" then
      reduce .members[] as $m ({acc: [], go: true};
        if .go then .acc += ($m | _leftsyms($N)) | .go = ($m | _nullable($N)) else . end)
      | .acc
    elif $t == "CHOICE" then [.members[] | _leftsyms($N)[]]
    elif has("content") then .content | _leftsyms($N)
    else []
    end;

def _check_left_recursion:
  .rules as $R
  | ({} | def go: . as $N | ($R | map_values(_nullable($N))) as $N2
                  | if $N2 == $N then $N else $N2 | go end;
          go) as $N
  | ($R | map_values(_leftsyms($N) | unique)) as $E
  | ($E | def close: . as $C | map_values((. + [.[] as $s | $C[$s][]?]) | unique)
                   | if . == $C then . else close end;
          close) as $reach
  | [$reach | to_entries[] | select(.key as $k | any(.value[]; . == $k)) | .key] as $cyc
  | if ($cyc | length) > 0
    then _gerr("left-recursive rule(s) not supported by a PEG parser: \($cyc | join(", "))")
    else . end;

# Validate and precompile a grammar (idempotent).
def compile_grammar:
  if type == "object" and .compiled == true then .
  elif type != "object" or (.rules | type) != "object" or (.rules | length) == 0 then
    _gerr("a grammar must be an object with a non-empty 'rules' object")
  else
    (.rules | keys_unsorted) as $names
    | {
        compiled: true,
        name: (.name // "grammar"),
        start: (.start // $names[0]),
        word: .word,
        rules: (.rules | with_entries(.key as $k | .value |= _crule($k; true))),
        extras: ((.extras // [{type: "PATTERN", value: "\\s"}]) | map(_crule("extras"; false)))
      }
    | ([.. | objects | select(.type == "SYMBOL") | .name] | unique) as $used
    | ($used - $names) as $undef
    | if ($undef | length) > 0 then _gerr("undefined symbol(s): \($undef | join(", "))") else . end
    | _check_left_recursion
  end;


# -----------------------------------------------------------------------------
# Parsing engine
# -----------------------------------------------------------------------------

def _default_opts:
  {start: null, single: false, lookahead: 0, window: 1024, backoff: 2, memo: true, newline: false, errors: "raise"};

# Attempt to match the start rule once, at codepoint position $p0 of $cps.
# Output: {kind: "match"|"wait"|"error"|"done", pos, nodes, err}
#   $G   compiled grammar      $o   options
#   $cps codepoint array       $eof true when no more input will follow
#   $off absolute offset (in codepoints) of $cps[0] in the whole input
def _attempt($G; $o; $cps; $blocks; $eof; $off; $p0):
  ($cps | length) as $len
  | $o.window as $W
  | $o.memo as $useMemo
  | ($o.start // $G.start) as $start

  # ---- regex matching on a bounded window (jq string slicing is O(n)) -----
  | def _rx($p; $re; $fl):
      if $p >= $len then ([("" | match($re; $fl))] | .[0].length)
      else
        (($p / $W) | floor) as $k
        | ([$len, ($k + 2) * $W] | min) as $wend
        | ([$blocks[$k][($p - $k * $W):] | match($re; $fl)] | .[0].length) as $L
        | if $wend < $len and $L != null and $L >= $wend - $p
          then [$cps[$p:] | implode | match($re; $fl)] | .[0].length
          else $L end
      end;

    # ---- children stack: immutable cons list [node, rest, length] ---------
    # NB: `a // b` is avoided in the engine: when `a` is truthy it leaves a
    # backtracking point alive that pins the state, so the next update of
    # .memo would copy the whole table (quadratic behaviour).
    def _klen: if .kids == null then 0 else .kids[2] end;
    def _push($x): .kids = [$x, .kids, (if .kids == null then 1 else .kids[2] + 1 end)];
    def _setfirst($p): if .first == null then .first = $p else . end;
    def _take($n): [limit($n; .kids | recurse(.[1]; . != null) | .[0])] | reverse;

    def _node($type; $st; $en; $ch):
      {type: $type, start: ($st + $off), end: ($en + $off)}
      + (if ($ch | length) > 0 then {children: $ch} else {text: ($cps[$st:$en] | implode)} end);

    # ---- the PEG interpreter --------------------------------------------
    # State: {ok, pos, kids, first, far, exp, touch, memo, sx, lb}
    def _fail_at($tok; $p; $label):
      if $tok then .
      elif $p > .far then .far = $p | .exp = [$label]
      elif $p == .far then .exp += [$label]
      else . end;
    def touch($i): if $i > .touch then .touch = $i else . end;
    def restore($b): .pos = $b.pos | .kids = $b.kids | .first = $b.first;

    def _m($r; $tok):
      def fail_at($p; $label): _fail_at($tok; $p; $label);
      def skip:
        if $tok then .
        elif .pos == .sx[1] then .
        elif .pos == .sx[0] then .pos = .sx[1]
        else
          {pos, kids, first} as $b
          | .ok = true
          | until(.ok | not;
              .pos as $p
              | reduce $G.extras[] as $x (.ok = false;
                  if .ok then .
                  else .pos = $p | .ok = true | _m($x; true)
                       | if .ok and .pos > $p then . else .pos = $p | .ok = false end
                  end))
          | .ok = true | .kids = $b.kids | .first = $b.first | .sx = [$b.pos, .pos]
        end;

      $r.type as $t
      | if $t == "STRING" then
          skip
          | .pos as $p
          | if $cps[$p:$p + $r.n] == $r.cps then
              .pos = $p + $r.n | touch($p + $r.n - 1)
              | if $r.n > 0 then _setfirst($p) else . end
            else
              (if ($len - $p) < $r.n and $r.cps[0:$len - $p] == $cps[$p:$len]
               then touch($len) else touch($p) end)
              | fail_at($p; $r.label) | .ok = false
            end

        elif $t == "PATTERN" then
          skip
          | .pos as $p
          | _rx($p; $r.re; $r.fl) as $L
          | if $L != null then
              .pos = $p + $L | touch($p + $L)
              | if $L > 0 then _setfirst($p) else . end
            else
              # A failed regex is assumed to be decided within `lookahead`
              # codepoints; closer than that to the end of the buffer, more
              # input might still make it match.
              (if $p + $o.lookahead >= $len then touch($len) else touch($p) end)
              | fail_at($p; $r.label) | .ok = false
            end

        elif $t == "SYMBOL" then
          ($r.name + "@" + (.pos | tostring) + (if $tok then "t" else "" end)) as $key
          | if $useMemo and .memo[$key] != null then
              .memo[$key] as $e
              | if $e.ok then .pos = $e.pos | _setfirst($e.first)
                              | reduce $e.nodes[] as $n (.; _push($n))
                else .ok = false end
            else
              {pos, kids, first, nk: _klen} as $b
              | (if $useMemo then .memo[$key] = {ok: false} else . end)   # left-recursion guard
              | .first = null
              | _m($G.rules[$r.name]; $tok)
              | if .ok then
                  (if .first == null then $b.pos else .first end) as $st
                  | _take(_klen - $b.nk) as $ch
                  | (if $r.name | startswith("_") then $ch else [_node($r.name; $st; .pos; $ch)] end) as $nodes
                  | (if $useMemo then .memo[$key] = {ok: true, pos, first: $st, nodes: $nodes} else . end)
                  | .kids = $b.kids | reduce $nodes[] as $n (.; _push($n))
                  | .first = (if $b.first == null then $st else $b.first end)
                else restore($b) end
            end

        elif $t == "SEQ" then
          {pos, kids, first} as $b
          | reduce $r.members[] as $m (.; if .ok then _m($m; $tok) else . end)
          | if .ok then . else restore($b) end

        elif $t == "CHOICE" then
          {pos, kids, first} as $b
          | if $tok then
              # longest match (lexer semantics) inside tokens
              .lb = [null] + .lb
              | reduce $r.members[] as $m (.;
                  restore($b) | .ok = true | _m($m; true)
                  | if .ok and (.lb[0] == null or .pos > .lb[0].pos) then .lb[0] = {pos, kids, first} else . end)
              | if .lb[0] != null then restore(.lb[0]) | .ok = true else restore($b) | .ok = false end
              | .lb = .lb[1:]
            else
              reduce $r.members[] as $m (.ok = false; if .ok then . else .ok = true | _m($m; $tok) end)
            end

        elif $t == "REPEAT" or $t == "REPEAT1" then
          def more:
            .ok = true
            | until(.ok | not;
                {pos, kids, first} as $b
                | _m($r.content; $tok)
                | if .ok and .pos > $b.pos then . else restore($b) | .ok = false end)
            | .ok = true;
          if $t == "REPEAT" then more else _m($r.content; $tok) | if .ok then more else . end end

        elif $t == "TOKEN" or $t == "IMMEDIATE_TOKEN" then
          (if $t == "TOKEN" then skip else . end)
          | {pos, kids, first} as $b
          | _m($r.content; true)
          | if .ok then .kids = $b.kids | (if .pos > $b.pos then _setfirst($b.pos) else . end)
            else fail_at($b.pos; $r.label) end

        elif $t == "FIELD" or $t == "ALIAS" then
          {pos, kids, first, nk: _klen} as $b
          | .first = null
          | _m($r.content; $tok)
          | if .ok then
              (if .first == null then $b.pos else .first end) as $st
              | _take(_klen - $b.nk) as $ch
              | (if $t == "FIELD" then
                   (if ($ch | length) == 0 and .pos > $st
                    then [{type: ($cps[$st:.pos] | implode), named: false, start: ($st + $off), end: (.pos + $off)}]
                    else $ch end)
                   | map(.field = $r.name)
                 elif $r.content.type == "SYMBOL" and ($ch | length) == 1 and $r.named then
                   [$ch[0] | .type = $r.value]
                 elif $r.named then [_node($r.value; $st; .pos; $ch)]
                 else [{type: $r.value, named: false, start: ($st + $off), end: (.pos + $off)}]
                 end) as $nodes
              | .kids = $b.kids | reduce $nodes[] as $n (.; _push($n))
              | .first = (if $b.first == null then $st else $b.first end)
            else restore($b) end   # restore `first`: CHOICE relies on failed alternatives leaving no trace

        elif $t == "BLANK" then .

        elif $t == "EOF" then
          skip
          | if .pos >= $len and $eof then .
            else touch(.pos) | fail_at(.pos; "end of input") | .ok = false end

        elif $t == "AND" or $t == "NOT" then
          {pos, kids, first} as $b
          | _m($r.content; $tok)
          | .ok as $ok
          | restore($b)
          | .ok = (if $t == "AND" then $ok else ($ok | not) end)
          | if .ok then . else fail_at($b.pos; (if $t == "AND" then "&" else "!" end) + "(...)") end

        else _gerr("unsupported rule type '\($t)'")
        end;

    # ---- one top-level attempt -----------------------------------------
    {ok: true, pos: $p0, kids: null, first: null, far: -1, exp: [], touch: -1,
     memo: {}, sx: [-1, -1], lb: []}
    # skip leading extras (a TOKEN around BLANK only skips)
    | _m({type: "TOKEN", content: {type: "BLANK"}, label: "token"}; false)
    | .pos as $ps
    | if $ps >= $len then
        if $eof then {kind: "done", pos: $len}
        else {kind: "wait"} end
      else
        _m(if $o.single then {type: "SEQ", members: [{type: "SYMBOL", name: $start}, {type: "EOF"}]}
           else {type: "SYMBOL", name: $start} end; false)
        | if .ok then
            if .pos == $ps then
              # matched nothing: wait for more input, or report the furthest failure
              if ($eof | not) and .touch >= $len then {kind: "wait"}
              elif .far > $ps then {kind: "error", pos: $ps, far, exp: (.exp | unique)}
              else {kind: "error", pos: $ps, far: $ps, exp: ["non-empty \($start)"]} end
            elif $eof or .touch < $len then
              {kind: "match", pos, nodes: _take(_klen), far: (.far + $off), exp: (.exp | unique)}
            else {kind: "wait"} end
          elif ($eof | not) and .touch >= $len then {kind: "wait"}
          else {kind: "error", pos: $ps, far: ([.far, $ps] | max), exp: (.exp | unique)}
          end
      end;

# Build a structured error from an attempt failure.
def _mkerror($cps; $st; $a):
  $a.far as $far
  | ($cps[0:$far] | indices([10])) as $nls
  | ($st.line + ($nls | length)) as $line
  | (if ($nls | length) > 0 then $far - $nls[-1]
     else $far + $st.off - $st.lastnl end) as $col
  | (if $far >= ($cps | length) then "end of input"
     else ($cps[$far:$far + 20] | implode | tojson) end) as $found
  | {
      message: ("syntax error at line \($line), column \($col): expected "
                + (if ($a.exp | length) > 0 then ($a.exp | join(" or ")) else "valid input" end)
                + ", found " + $found),
      position: ($far + $st.off),
      line: $line,
      column: $col,
      expected: $a.exp,
      found: $found
    };

# Core streaming driver: parse the stream of strings `chunks`.
# Emits one AST per complete top-level match of the start rule.
def parse_stream($grammar; $opts; chunks):
  ($grammar | compile_grammar) as $G
  | (_default_opts + ($opts // {})) as $o
  | if $G.rules[$o.start // $G.start] == null then _gerr("unknown start rule '\($o.start)'") else . end
  | (($o.start // $G.start) | startswith("_")) as $hiddenStart
  | label $done
  | foreach ((chunks | if type == "string" then {c: .} else _gerr("input chunks must be strings, got \(type)") end),
             {eof: true}) as $ev
      ({buf: "", off: 0, line: 1, lastnl: -1, out: [], stop: false, prev: null, next: 0};
       .out = []
       | .buf += (if $ev.eof then "" elif $o.newline then $ev.c + "\n" else $ev.c end)
       | ($ev.eof == true) as $eof
       # Back-off: after an inconclusive attempt, wait until the buffer has
       # grown by the `backoff` factor before re-parsing it. This keeps the
       # total work linear when one large AST arrives in many small chunks.
       | if ($eof | not) and (.buf | length) < .next then .
         else
           (.buf | explode) as $cps
           | ([range(0; $cps | length; $o.window) as $i | $cps[$i:$i + 2 * $o.window] | implode]) as $blocks
           | .p = 0 | .go = true
           | until(.go | not;
               _attempt($G; $o; $cps; $blocks; $eof; .off; .p) as $a
               | if $a.kind == "match" then
                   .out += [if $hiddenStart then $a.nodes[] else $a.nodes[0] end] | .p = $a.pos
                   | .prev = {far: $a.far, exp: $a.exp}
                 elif $a.kind == "error" then
                   # A failure that got further while matching the previous
                   # record is usually the more informative one.
                   (if .prev != null and .prev.far > $a.far + .off
                      then {far: (.prev.far - .off), exp: .prev.exp} else $a end) as $e
                   | .out += [{error: _mkerror($cps; {line, off, lastnl}; $e)}]
                   | .go = false | .stop = true
                 else .go = false end)
           | if .p > 0 then
               ($cps[0:.p] | indices([10])) as $nls
               | (if ($nls | length) > 0 then .line += ($nls | length) | .lastnl = .off + $nls[-1] else . end)
               | .buf = ($cps[.p:] | implode)
               | .off += .p
             else . end
           | .next = ((($cps | length) - .p) * $o.backoff | floor)
         end;
       (.out[]
        | if has("error") then
            if $o.errors == "emit" then . else error(.error) end
          else . end),
       (if .stop then break $done else empty end));

def parse_stream($grammar; chunks): parse_stream($grammar; {}; chunks);

# Parse `.` (when it is a string) followed by all remaining `inputs`.
# Typical use:  jq -nR --slurpfile g grammar.json 'parse($g[0]; {newline: true})'
#          or:  jq -n --rawfile s file.txt --argjson g ... '$s | parse_string($g)'
def parse($grammar; $opts):
  parse_stream($grammar; $opts; (if type == "string" then . elif . == null then empty
                                 else _gerr("parse: input must be a string") end),
                                inputs);
def parse($grammar): parse($grammar; {});

# Parse a single string (no `inputs` are consumed).
def parse_string($grammar; $opts): . as $s | parse_stream($grammar; $opts; $s);
def parse_string($grammar): parse_string($grammar; {});


# -----------------------------------------------------------------------------
# AST utilities
# -----------------------------------------------------------------------------

# All nodes of an AST, pre-order.
def nodes: recurse(.children[]?);

# Remove start/end offsets (handy for comparisons in tests).
def strip_positions: walk(if type == "object" then del(.start, .end) else . end);

# Render an AST as a tree-sitter style S-expression, e.g.
#   (document (object (pair key: (string (string_content)) value: (number))))
# Anonymous nodes are omitted unless they carry a field name.
def to_sexp:
  def go:
    (if .field then .field + ": " else "" end) as $f
    | if .named == false then $f + (.type | tojson)
      else
        [.children[]? | select(.named != false or .field != null) | go] as $cs
        | $f + "(" + .type + (if ($cs | length) > 0 then " " + ($cs | join(" ")) else "" end) + ")"
      end;
  go;
