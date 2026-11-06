JQ ?= jq

.PHONY: test test-jq bench grammars

test:
	JQ=$(JQ) python3 tests/run_tests.py

# jq has --run-tests; for other implementations (gojq, jaq) the runner emulates it
test-jq:
	@if $(JQ) --version | grep -q '^jq-'; then $(JQ) -L . --run-tests tests/parse.test; \
	else JQ=$(JQ) python3 tests/run_tests.py JqTestSuites; fi

bench:
	JQ=$(JQ) python3 tests/run_tests.py --bench

# Regenerate the JSON grammars written with the jq DSL (grammars/src/*.jq)
grammars: grammars/sparql11.json grammars/jq.json

grammars/%.json: grammars/src/%.jq jq-parser-generator.jq
	$(JQ) -n -L . -f $< > $@
