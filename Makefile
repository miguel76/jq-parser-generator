JQ ?= jq

.PHONY: test test-jq bench

test:
	JQ=$(JQ) python3 tests/run_tests.py

test-jq:
	$(JQ) -L . --run-tests tests/parse.test

bench:
	JQ=$(JQ) python3 tests/run_tests.py --bench
