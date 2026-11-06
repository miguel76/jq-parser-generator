#!/usr/bin/env python3
"""Test runner for jq-parser-generator (Python standard library only).

    python3 tests/run_tests.py              # functional + CLI + resource tests
    python3 tests/run_tests.py --bench      # only print the resource report
    python3 -m pytest tests/run_tests.py    # also works, if pytest is installed

Resource tests measure, for every jq process they spawn, the CPU time
(os.wait4) and the peak resident set size (VmHWM sampled from /proc on
Linux, ru_maxrss elsewhere). They check:

  * absolute budgets (time and memory) for fixed workloads;
  * scaling: doubling the input must roughly double the time (linear, not
    quadratic) and memory must grow at most linearly;
  * streaming: emitting many small ASTs from a long stream must run in
    (nearly) constant memory, because consumed input is discarded.

Absolute budgets are deliberately generous; multiply them with
JQPG_PERF_SLACK (e.g. JQPG_PERF_SLACK=3 on a slow CI machine). Scaling ratios
are machine independent and are never relaxed. Set JQPG_PERF_REPORT=path.json to
write the measurements to a file.

jq 1.8.0 is known to be unusable for the resource tests: its reduce/foreach
keep an extra reference to the state (jqlang/jq#3205, reverted in 1.8.1), so
every update copies the container and parsing becomes quadratic. Resource
tests are skipped on 1.8.0 unless JQPG_PERF_FORCE=1 (or --bench) is set.
The reference version is jq 1.8.1 or newer.
"""

import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JQ = os.environ.get("JQ", "jq")
SLACK = float(os.environ.get("JQPG_PERF_SLACK", "1"))
REPORT = []


def jq_version():
    try:
        return subprocess.run([JQ, "--version"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


JQ_VERSION = jq_version()
# jq 1.8.0 copies reduce/foreach state on every update (fixed in 1.8.1)
JQ_SLOW_REDUCE = JQ_VERSION == "jq-1.8.0"


def _vmhwm_kib(pid):
    """Peak RSS of the process' *current* memory image (Linux /proc)."""
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def measure(args, stdin=b""):
    """Run jq and return (stdout, cpu_seconds, peak_rss_kib).

    CPU time (user+sys) comes from wait4(). Peak memory is sampled from
    /proc/<pid>/status (VmHWM) while jq runs: getrusage's ru_maxrss is not
    usable here because on Linux it keeps the high-water mark of the image
    *before* exec, i.e. of the forking Python interpreter. Elsewhere we fall
    back to ru_maxrss.
    """
    proc = subprocess.Popen(
        [JQ, "-L", str(ROOT)] + args,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=str(ROOT),
    )
    out_chunks, err_chunks, hwm = [], [], [None]
    done = threading.Event()

    def _reader(stream, sink):
        sink.append(stream.read())
        stream.close()

    def _sampler():
        while not done.is_set():
            v = _vmhwm_kib(proc.pid)
            if v is not None:
                hwm[0] = max(hwm[0] or 0, v)
            done.wait(0.005)

    threads = [threading.Thread(target=_reader, args=(proc.stdout, out_chunks)),
               threading.Thread(target=_reader, args=(proc.stderr, err_chunks)),
               threading.Thread(target=_sampler)]
    for t in threads:
        t.start()
    try:
        proc.stdin.write(stdin)
    except BrokenPipeError:
        pass
    proc.stdin.close()
    threads[0].join()
    threads[1].join()
    # take a last sample while the process is (probably) still a non-zombie
    _, status, rusage = os.wait4(proc.pid, 0)
    done.set()
    threads[2].join()
    proc.returncode = os.waitstatus_to_exitcode(status)
    if proc.returncode != 0:
        raise AssertionError(f"jq failed ({proc.returncode}): {err_chunks[0].decode()}")
    cpu = rusage.ru_utime + rusage.ru_stime
    rss = hwm[0]
    if rss is None:  # not Linux, or the process was too short-lived to sample
        rss = rusage.ru_maxrss // (1024 if sys.platform == "darwin" else 1)
    return out_chunks[0], cpu, rss


def best_of(n, args, stdin=b""):
    """Minimum time / memory over n runs (reduces noise)."""
    runs = [measure(args, stdin) for _ in range(n)]
    out = runs[0][0]
    return out, min(r[1] for r in runs), min(r[2] for r in runs)


def record(name, size, seconds, rss, **extra):
    row = {"benchmark": name, "input_bytes": size, "cpu_seconds": round(seconds, 3),
           "peak_rss_kib": rss}
    if size:
        row["kib_per_second"] = round(size / 1024 / seconds, 2)
    row.update(extra)
    REPORT.append(row)
    return row


def json_doc(n_items, seed=1):
    rnd = random.Random(seed)
    return json.dumps([
        {"id": i, "name": f"item{i}", "tags": ["a", "b"], "value": rnd.random(),
         "ok": i % 2 == 0, "none": None}
        for i in range(n_items)
    ], indent=1).encode()


def json_lines(n_records, seed=2):
    rnd = random.Random(seed)
    return "".join(
        json.dumps({"n": i, "v": rnd.randint(0, 1000)}) + "\n"
        for i in range(n_records)
    ).encode()


PARSE_DOC = ('import "jq-parser-generator" as P; import "grammars/json" as $g; '
             'P::parse_string($g[0]; {start: "document"}) | [P::nodes] | length')
STREAM_LINES = ('import "jq-parser-generator" as P; import "grammars/json" as $g; '
                'P::parse($g[0]; {start: "_value", newline: true}) | .end')


# ---------------------------------------------------------------------------
# Functional tests
# ---------------------------------------------------------------------------

def has_run_tests():
    """jq has --run-tests; gojq and other implementations do not."""
    return JQ_VERSION.startswith("jq-")


def keeps_key_order():
    proc = subprocess.run([JQ, "-nc", '{b: 1, a: 2} | [to_entries[].key]'],
                          capture_output=True, text=True)
    return proc.stdout.strip() == '["b","a"]'


def supports_regex_lookahead():
    """Oniguruma (jq) has (?!...); Go's regexp (gojq) has no lookaround."""
    proc = subprocess.run([JQ, "-n", '"ab" | test("a(?!c)")'],
                          capture_output=True, text=True)
    return proc.stdout.strip() == "true"


def read_test_cases(path):
    """Parse a jq --run-tests file into (line, program, input, expected, needs)."""
    lines = path.read_text().split("\n")
    cases, needs, i = [], set(), 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            needs, i = set(), i + 1
            continue
        if line.startswith("#"):
            m = re.match(r"#\s*needs:\s*([\w-]+)", line)
            if m:
                needs.add(m.group(1))
            i += 1
            continue
        if line.startswith("%%FAIL"):
            raise ValueError(f"{path.name}:{i + 1}: %%FAIL cases need jq --run-tests")
        start, program, stdin = i + 1, line, lines[i + 1]
        i += 2
        expected = []
        while i < len(lines) and lines[i].strip():
            expected.append(lines[i])
            i += 1
        cases.append((start, program, stdin, expected, needs))
        needs = set()
    return cases


class JqTestSuites(unittest.TestCase):
    """Runs every tests/*.test file with `jq --run-tests`.

    Implementations without --run-tests (gojq) get an emulation: each case
    runs as its own process and outputs are compared as JSON values. Cases
    marked `# needs: key-order` are skipped where object key order is lost.
    """

    def test_suites(self):
        files = sorted((ROOT / "tests").glob("*.test"))
        self.assertTrue(files, "no .test files found")
        for f in files:
            with self.subTest(file=f.name):
                if has_run_tests():
                    self.run_native(f)
                else:
                    self.run_emulated(f)

    def run_native(self, f):
        proc = subprocess.run([JQ, "-L", str(ROOT), "--run-tests", str(f)],
                              capture_output=True, cwd=str(ROOT))
        text = proc.stdout.decode() + proc.stderr.decode()
        m = re.search(r"(\d+) of (\d+) tests passed \((\d+) malformed", text)
        self.assertIsNotNone(m, text)
        failures = [l for l in text.splitlines() if l.startswith("***")]
        self.assertEqual(m.group(1), m.group(2), "\n".join(failures))
        self.assertEqual(m.group(3), "0", "malformed tests")

    def run_emulated(self, f):
        key_order = keeps_key_order()
        failures, skipped, cases = [], 0, read_test_cases(f)
        for line, program, stdin, expected, needs in cases:
            if "key-order" in needs and not key_order:
                skipped += 1
                continue
            proc = subprocess.run([JQ, "-L", str(ROOT), "-c", program], input=stdin.encode(),
                                  capture_output=True, cwd=str(ROOT))
            try:
                got = [json.loads(l) for l in proc.stdout.decode().splitlines() if l.strip()]
            except ValueError:
                got = proc.stdout.decode()
            if proc.returncode != 0 or got != [json.loads(e) for e in expected]:
                failures.append(f"line {line}: {program}\n  expected {expected}\n  got {got}"
                                f"\n  {proc.stderr.decode().strip()}")
        print(f"{f.name}: {len(cases) - skipped - len(failures)} of {len(cases)} passed, "
              f"{skipped} skipped (emulated --run-tests)", file=sys.stderr)
        self.assertFalse(failures, "\n".join(failures))


class CliTests(unittest.TestCase):
    """End-to-end usage of parse($grammar) reading from jq's input stream."""

    def jq(self, args, stdin=b""):
        proc = subprocess.run([JQ, "-L", str(ROOT)] + args, input=stdin,
                              capture_output=True, cwd=str(ROOT))
        return proc.returncode, proc.stdout.decode(), proc.stderr.decode()

    def test_raw_lines(self):
        rc, out, _ = self.jq(["-nRc", "--slurpfile", "g", "grammars/csv.json",
                              'import "jq-parser-generator" as P; '
                              'P::parse($g[0]; {start: "record", newline: true}) | P::to_sexp'],
                             b'a,b\n"multi\nline",c\n')
        self.assertEqual(rc, 0)
        self.assertEqual(out.splitlines(), ['"(record (field) (field))"',
                                            '"(record (quoted (text)) (field))"'])

    def test_json_string_inputs_without_n(self):
        # without -n the first input is `.`, the others come from `inputs`
        rc, out, _ = self.jq(["-c", "--slurpfile", "g", "grammars/arithmetic.json",
                              'import "jq-parser-generator" as P; '
                              'P::parse($g[0]; {start: "expression", single: true}) | P::to_sexp'],
                             b'"1+" "2" "*3"')
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out),
                         '(expression (sum (number) operator: "+" (product (number) operator: "*" (number))))')

    def test_whole_file(self):
        rc, out, _ = self.jq(["-Rsc", "--slurpfile", "g", "grammars/json.json",
                              'import "jq-parser-generator" as P; P::parse($g[0]; {start: "document"}) | P::to_sexp'],
                             b'{"a": [1, 2]}\n')
        self.assertEqual(rc, 0)
        self.assertIn("(document (object (pair", out)

    def test_error_exit_status(self):
        rc, out, err = self.jq(["-nR", "--slurpfile", "g", "grammars/json.json",
                                'import "jq-parser-generator" as P; P::parse($g[0]; {start: "document", newline: true})'],
                               b'{"a": }\n')
        self.assertNotEqual(rc, 0)
        self.assertIn("syntax error at line 1, column 7", err)

    def test_error_emit(self):
        rc, out, _ = self.jq(["-nRc", "--slurpfile", "g", "grammars/json.json",
                              'import "jq-parser-generator" as P; '
                              'P::parse($g[0]; {newline: true, start: "_value", errors: "emit"}) '
                              '| if .error then .error | {line, column} else .type end'],
                             b'1\n[2]\n{x}\n')
        self.assertEqual(rc, 0)
        self.assertEqual([json.loads(l) for l in out.splitlines()],
                         ["number", "array", {"line": 3, "column": 2}])

    def test_example_calculator(self):
        rc, out, err = self.jq(["-nR", "--slurpfile", "g", "grammars/arithmetic.json",
                                "-f", "examples/calc.jq"],
                               b"1 + 2*3\n-(4 - 10) % 4\n\n2 * (3 + 4) * 5\n")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.split(), ["7", "2", "70"])

    def test_jqpm_layout(self):
        """The package is importable the way jqpm installs it."""
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            pkg = Path(tmp) / "jq_modules" / "miguel76" / "jq-parser-generator"
            pkg.mkdir(parents=True)
            shutil.copy(ROOT / "jq-parser-generator.jq", pkg)
            proc = subprocess.run(
                [JQ, "-nc", "-L", str(Path(tmp) / "jq_modules"),
                 'import "miguel76/jq-parser-generator" as P; '
                 '"x y" | [P::parse_string({rules: {s: ["x", "y"]}})] | length'],
                capture_output=True)
            self.assertEqual(proc.returncode, 0, proc.stderr.decode())
            self.assertEqual(proc.stdout.decode().strip(), "1")

    def test_generated_grammars_up_to_date(self):
        """grammars/X.json is the output of grammars/src/X.jq (`make grammars`)."""
        for src in sorted((ROOT / "grammars" / "src").glob("*.jq")):
            rc, out, err = self.jq(["-n", "-f", str(src)])
            self.assertEqual(rc, 0, err)
            committed = json.loads((ROOT / "grammars" / (src.stem + ".json")).read_text())
            self.assertEqual(json.loads(out), committed, f"run `make grammars` ({src.name})")

    @unittest.skipUnless(supports_regex_lookahead(),
                         "grammars/sparql11.json and grammars/jq.json use regex lookahead (?!...)")
    def test_sparql_and_jq_grammars(self):
        rc, out, err = self.jq(["-nrc", "--slurpfile", "s", "grammars/sparql11.json",
                                "--slurpfile", "j", "grammars/jq.json",
                                'import "jq-parser-generator" as P; '
                                '("PREFIX : <x:> SELECT * { ?s :p/:q* [ :r 1 ] } LIMIT 2" '
                                ' | P::parse_string($s[0]; {single: true}) | [P::nodes.type] | length), '
                                '("INSERT DATA { <a> <b> \\"c\\" }" '
                                ' | P::parse_string($s[0]; {single: true, start: "UpdateUnit"}) | .children[0].type), '
                                '(".a as $x | 1 + 2 * 3, -$x" '
                                ' | P::parse_string($j[0]; {single: true}) | P::to_sexp)'])
        self.assertEqual(rc, 0, err)
        lines = out.splitlines()
        self.assertEqual(lines[1], "InsertData")
        self.assertEqual(lines[2], '(program (binding source: (field) (variable) body: (comma '
                                   '(additive (number) operator: "+" (multiplicative (number) operator: "*" (number))) '
                                   '(negation (variable)))))')

    def test_manifest(self):
        manifest = json.loads((ROOT / "jqpackage.json").read_text())
        self.assertEqual(manifest["name"], "jq-parser-generator")
        self.assertTrue((ROOT / manifest["main"]).exists())
        rc, out, _ = self.jq(["-n", '"jq-parser-generator" | modulemeta | .version'])
        self.assertEqual(json.loads(out), manifest["version"])


# ---------------------------------------------------------------------------
# Resource (time / memory) tests
# ---------------------------------------------------------------------------

class ResourceTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if JQ_SLOW_REDUCE and os.environ.get("JQPG_PERF_FORCE") != "1":
            raise unittest.SkipTest(
                "jq 1.8.0 has a quadratic reduce/foreach regression (fixed in 1.8.1); "
                "set JQPG_PERF_FORCE=1 to run anyway")
        # a short busy loop, so that jq lives long enough to be sampled
        _, cls.base_seconds, cls.base_rss = best_of(
            3, ["-n", 'include "jq-parser-generator"; reduce range(300000) as $i (0; . + $i)'])
        record("baseline (jq + module load, busy loop)", 0, cls.base_seconds, cls.base_rss)

    def test_json_document_scaling(self):
        """Parse time grows linearly with document size; memory stays modest."""
        rows = []
        for n in (50, 100, 200):
            doc = json_doc(n)
            out, sec, rss = best_of(2, ["-R", "-s", PARSE_DOC], doc)
            self.assertGreater(int(out), n * 10)
            rows.append((len(doc), sec, rss))
            record("json document (tree-sitter-json grammar)", len(doc), sec, rss, items=n)
        (s1, t1, m1), _, (s4, t4, m4) = rows
        size_ratio = s4 / s1
        # linear => ratio ~4; quadratic would be ~16
        self.assertLess(t4 / t1, size_ratio * 1.6,
                        f"parse time does not scale linearly: {rows}")
        # absolute budgets
        self.assertLess(t4, 15 * SLACK, f"too slow: {t4:.2f}s for {s4} bytes")
        self.assertLess(m4 - self.base_rss, 64 * 1024 * SLACK,
                        f"too much memory: {m4} KiB for {s4} bytes")
        # memory grows at most linearly with the input
        self.assertLess((m4 - self.base_rss), max(m1 - self.base_rss, 1024) * size_ratio * 1.5)

    def test_streaming_constant_memory(self):
        """Emitting many small ASTs from a stream runs in ~constant memory."""
        rows = []
        for n in (500, 2000):
            data = json_lines(n)
            out, sec, rss = best_of(2, ["-nR", STREAM_LINES], data)
            self.assertEqual(len(out.splitlines()), n)
            rows.append((len(data), sec, rss))
            record("json lines stream (start=_value, newline)", len(data), sec, rss, records=n)
        (s1, t1, m1), (s4, t4, m4) = rows
        self.assertLess(t4 / t1, (s4 / s1) * 1.6, f"stream not linear: {rows}")
        # 4x the input must not need noticeably more memory
        self.assertLess(m4, m1 * 1.25 + 2048, f"stream memory grows: {rows}")

    def test_single_record_spread_over_many_chunks(self):
        """A large AST arriving in many small chunks (re-parsing cost)."""
        doc = json_doc(60)
        lines = doc  # indent=1 => one chunk per line, ~8 lines per item
        out, sec, rss = best_of(1, ["-nR",
                                    'import "jq-parser-generator" as P; import "grammars/json" as $g; '
                                    'P::parse($g[0]; {start: "document", newline: true}) | [P::nodes] | length'], lines)
        record("json document fed line by line", len(doc), sec, rss,
               chunks=doc.count(b"\n"))
        self.assertGreater(int(out), 600)
        self.assertLess(sec, 15 * SLACK)

    def test_deep_nesting(self):
        depth = 300
        doc = ("[" * depth + "1" + "]" * depth).encode()
        out, sec, rss = best_of(1, ["-R", "-s", PARSE_DOC], doc)
        record("deeply nested arrays", len(doc), sec, rss, depth=depth)
        self.assertEqual(int(out), depth + 2)
        self.assertLess(sec, 10 * SLACK)

    def test_long_repetition(self):
        """Long flat repetition (exercises the children stack and REPEAT loop)."""
        n = 20000
        data = (" ".join(str(i % 10) for i in range(n))).encode()
        prog = ('import "jq-parser-generator" as P; '
                'P::parse_string({start: "list", rules: {list: P::repeat(P::sym("d")), d: P::pat("[0-9]")}}) '
                '| .children | length')
        out, sec, rss = best_of(1, ["-R", "-s", prog], data)
        record("flat repetition of 20k items", len(data), sec, rss, items=n)
        self.assertEqual(int(out), n)
        self.assertLess(sec, 20 * SLACK)
        self.assertLess(rss - self.base_rss, 96 * 1024 * SLACK)


def print_report():
    if not REPORT:
        return
    cols = ["benchmark", "input_bytes", "cpu_seconds", "kib_per_second", "peak_rss_kib"]
    widths = {c: max(len(c), *(len(str(r.get(c, ""))) for r in REPORT)) for c in cols}
    print("\nResource report", file=sys.stderr)
    print("  ".join(c.ljust(widths[c]) for c in cols), file=sys.stderr)
    for r in REPORT:
        print("  ".join(str(r.get(c, "")).ljust(widths[c]) for c in cols), file=sys.stderr)
    path = os.environ.get("JQPG_PERF_REPORT")
    if path:
        Path(path).write_text(json.dumps(REPORT, indent=2) + "\n")


def tearDownModule():
    print_report()


if __name__ == "__main__":
    print(f"using {JQ} ({JQ_VERSION})", file=sys.stderr)
    if "--bench" in sys.argv:
        sys.argv.remove("--bench")
        os.environ["JQPG_PERF_FORCE"] = "1"
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ResourceTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        sys.exit(0 if result.wasSuccessful() else 1)
    unittest.main(verbosity=2)
