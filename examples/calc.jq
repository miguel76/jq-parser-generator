# A tiny calculator: parse arithmetic with grammars/arithmetic.json and
# evaluate the AST. One expression per input line.
#
#   printf '1 + 2*3\n-(4 - 10) %% 4\n' |
#     jq -nR -L . --slurpfile g grammars/arithmetic.json -f examples/calc.jq

import "jq-parser-generator" as P;

def ev:
  if .type == "number" then .text | tonumber
  elif .type == "negation" then - (.children[0] | ev)
  elif .type == "expression" then .children[0] | ev
  else # sum / product: operand (operator operand)*
    .children as $c
    | reduce range(1; $c | length; 2) as $i ($c[0] | ev;
        ($c[$i + 1] | ev) as $y
        | $c[$i].type as $op
        | if   $op == "+" then . + $y
          elif $op == "-" then . - $y
          elif $op == "*" then . * $y
          elif $op == "/" then . / $y
          else . % $y end)
  end;

# The grammar treats newlines as whitespace, so `P::parse` over the whole
# input would read "1\n-2" as one expression. Parse each line on its own.
inputs | select(test("\\S")) | P::parse_string($g[0]; {single: true}) | ev
