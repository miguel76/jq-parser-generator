#!/usr/bin/env python3
"""Run external conformance corpora through the bundled SPARQL and jq grammars.

The corpora are not vendored. Point the script at local checkouts:

  # SPARQL 1.1: W3C rdf-tests (https://github.com/w3c/rdf-tests), sparql/ dir
  python3 tests/conformance.py sparql /path/to/rdf-tests/sparql

  # jq 1.8: the jq source tree at tag jq-1.8.0 (tests/*.test, src/builtin.jq)
  python3 tests/conformance.py jq /path/to/jq

The SPARQL run uses every Positive/Negative(Update)SyntaxTest(11) entry of the
manifests found under the directory. The jq run parses every program of the
jq --run-tests files (positive unless listed under %%FAIL) and src/builtin.jq.

Options: --verbose lists each failure, --json FILE writes the per-test results.
Uses only the Python standard library. Exit status is always 0: the script
reports, it does not assert (see docs/sparql-and-jq.md for the known gaps).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JQ = os.environ.get("JQ", "jq")

RUNNER = r'''
import "jq-parser-generator" as P;
($g[0] | P::compile_grammar) as $G
| inputs as $t
| ($t.text | try ([P::parse_string($G; {single: true, start: $t.start})] | if length == 0 then "no output" else null end) catch .) as $e
| select($e != "no output")
| {id: $t.id, ok: ($e == null), error: (if $e == null then null elif ($e | type) == "object" then $e.message else $e end)}
'''


def run(grammar, cases):
    """cases: list of dicts {id, start, text, expect} -> list of results."""
    payload = "".join(json.dumps({"id": c["id"], "start": c["start"], "text": c["text"]}) + "\n" for c in cases)
    t0 = time.time()
    p = subprocess.run([JQ, "-nc", "-L", ROOT, "--slurpfile", "g", grammar, RUNNER],
                       input=payload.encode(), capture_output=True, check=True)
    elapsed = time.time() - t0
    out = {r["id"]: r for r in map(json.loads, p.stdout.decode().splitlines())}
    results = []
    for c in cases:
        # With {single: true}, input made only of whitespace/comments yields
        # no AST and no error (library limitation, see the docs): count it
        # as accepted, with a note.
        r = out.get(c["id"], {"ok": True, "error": "accepted without an AST (input is empty)"})
        results.append(dict(c, ok=r["ok"], error=r["error"], passed=(r["ok"] == c["expect"])))
    return results, elapsed


# ------------------------------------------------------------------ SPARQL

ENTRY = re.compile(r"(?:rdf:type|\ba)\s+mf:(\w*SyntaxTest\w*)")
ACTION = re.compile(r"mf:action\s+<([^>]+)>")


def sparql_cases(base):
    cases = []
    for d, _, files in os.walk(base):
        if "manifest.ttl" not in files:
            continue
        text = open(os.path.join(d, "manifest.ttl"), encoding="utf-8").read()
        for block in re.split(r"\n\s*\n", text):
            m = ENTRY.search(block.strip())
            if not m:
                continue
            kind = m.group(1)
            a = ACTION.search(block)
            if not a:
                continue
            path = os.path.join(d, a.group(1))
            if not os.path.exists(path):
                continue
            src = open(path, encoding="utf-8").read()
            update = "Update" in kind or path.endswith(".ru")
            cases.append({
                "id": os.path.relpath(path, base),
                "kind": kind,
                "start": "UpdateUnit" if update else "QueryUnit",
                "text": src,
                "expect": kind.startswith("Positive"),
            })
    return sorted(cases, key=lambda c: c["id"])


# ---------------------------------------------------------------------- jq

def jq_cases(base):
    cases = []
    for name in ("jq.test", "man.test", "base64.test", "onig.test", "optional.test", "manonig.test",
                 "uri.test"):
        path = os.path.join(base, "tests", name)
        if not os.path.exists(path):
            continue
        lines = open(path, encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            line = lines[i]
            if not line.strip() or line.startswith("#"):
                i += 1
                continue
            if line.startswith("%%FAIL"):
                # %%FAIL [IGNORE MSG]\n<program>\n<error message>...
                prog = lines[i + 1]
                cases.append({"id": f"{name}:{i + 2}", "kind": "fail", "start": None, "text": prog, "expect": False})
            else:
                cases.append({"id": f"{name}:{i + 1}", "kind": "ok", "start": None, "text": line, "expect": True})
            # skip to the next blank line
            while i < len(lines) and lines[i].strip():
                i += 1
    for rel in ("src/builtin.jq",):
        path = os.path.join(base, rel)
        if os.path.exists(path):
            cases.append({"id": rel, "kind": "ok", "start": None,
                          "text": open(path, encoding="utf-8").read(), "expect": True})
    return cases


# Fully parenthesised re-printing of a jq AST: every operator node is
# wrapped in parentheses, everything else is copied from the source. If the
# grammar got a precedence or associativity wrong, the re-printed program
# computes something else.
UNPARSE = r'''
import "jq-parser-generator" as P;
def wrap: ["pipe", "comma", "alternative", "assignment", "or", "and", "comparison", "additive",
           "multiplicative", "negation", "binding", "local_definition", "label", "try", "reduce",
           "foreach", "if", "suffixed"] as $w | .type as $t | any($w[]; . == $t);
def unparse($cps; $ctx):
  if .children == null then $cps[.start:.end] | implode
  else
    . as $n
    | (if .type == "module" or .type == "import" then false else $ctx end) as $c
    | reduce .children[] as $k ({pos: $n.start, out: ""};
        .out += ($cps[.pos:$k.start] | implode) + ($k | unparse($cps; $c)) | .pos = $k.end)
    | .out + ($cps[.pos:$n.end] | implode)
    | if $c and ($n | wrap) then "(" + . + ")" else . end
  end;
($g[0] | P::compile_grammar) as $G
| inputs as $t
| ($t.text | explode) as $cps
| {id: $t.id, text: (try ($t.text | P::parse_string($G; {single: true}) | unparse($cps; true)) catch null)}
'''


def jq_roundtrip(base, verbose):
    """Re-print every program of tests/jq.test and tests/man.test fully
    parenthesised, run the original and the re-printed program with the local
    jq on the test's input, and compare outputs and exit status."""
    grammar = os.path.join(ROOT, "grammars", "jq.json")
    progs = [c for c in jq_cases(base) if c["kind"] == "ok" and c["id"].split(":")[0] in ("jq.test", "man.test")]
    payload = "".join(json.dumps({"id": c["id"], "text": c["text"]}) + "\n" for c in progs)
    p = subprocess.run([JQ, "-nc", "-L", ROOT, "--slurpfile", "g", grammar, UNPARSE],
                       input=payload.encode(), capture_output=True, check=True)
    reprinted = {r["id"]: r["text"] for r in map(json.loads, p.stdout.decode().splitlines())}
    files = {}

    def run_jq(prog, inp):
        try:
            q = subprocess.run([JQ, "-c", "-L", os.path.join(base, "tests", "modules"), prog],
                               input=inp.encode(), capture_output=True, timeout=10, cwd=base)
            return q.returncode, q.stdout
        except subprocess.TimeoutExpired:
            return "timeout", b""

    same = differ = skipped = 0
    for c in progs:
        name, line = c["id"].split(":")
        lines = files.setdefault(name, open(os.path.join(base, "tests", name), encoding="utf-8").read().split("\n"))
        new = reprinted.get(c["id"])
        if new is None or new == c["text"]:
            skipped += 1
            continue
        inp = lines[int(line)]  # the line after the program
        a, b = run_jq(c["text"], inp), run_jq(new, inp)
        if a == b:
            same += 1
        else:
            differ += 1
            print(f"  {c['id']}: {c['text']}\n      -> {new}\n      {a!r}\n      {b!r}")
    print(f"jq round-trip with {JQ}: {same} programs behave the same after re-printing, "
          f"{differ} differ, {skipped} unchanged/not parsed")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("language", choices=["sparql", "jq", "jq-roundtrip"])
    ap.add_argument("corpus")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args()

    if args.language == "jq-roundtrip":
        return jq_roundtrip(args.corpus, args.verbose)
    if args.language == "sparql":
        cases, grammar = sparql_cases(args.corpus), os.path.join(ROOT, "grammars", "sparql11.json")
    else:
        cases, grammar = jq_cases(args.corpus), os.path.join(ROOT, "grammars", "jq.json")
    if not cases:
        sys.exit(f"no test cases found under {args.corpus}")

    results, elapsed = run(grammar, cases)
    groups = {}
    for r in results:
        groups.setdefault(r["expect"], []).append(r)
    print(f"{args.language}: {len(results)} cases in {elapsed:.1f}s")
    for expect, label in ((True, "positive (must parse)"), (False, "negative (must be rejected)")):
        rs = groups.get(expect, [])
        if rs:
            passed = sum(r["passed"] for r in rs)
            print(f"  {label:28s} {passed:4d}/{len(rs):<4d} passed")
    if args.verbose:
        for r in results:
            if not r["passed"]:
                what = "rejected" if r["expect"] else "accepted"
                print(f"\n--- {r['id']} ({r['kind']}): wrongly {what}")
                if r["error"]:
                    print("    " + r["error"])
                print("    " + r["text"].strip().replace("\n", "\n    ")[:600])
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
