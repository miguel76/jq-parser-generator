JQ ?= jq

.PHONY: test test-jq bench grammars

test:
	JQ=$(JQ) python3 tests/run_tests.py

test-jq:
	$(JQ) -L . --run-tests tests/parse.test

bench:
	JQ=$(JQ) python3 tests/run_tests.py --bench

# Regenerate the JSON grammars written with the jq DSL (grammars/src/*.jq)
grammars: grammars/sparql11.json grammars/jq.json

grammars/%.json: grammars/src/%.jq jq-parser-generator.jq
	$(JQ) -n -L . -f $< > $@
