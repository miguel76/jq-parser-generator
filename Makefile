JQ ?= jq

.PHONY: test test-jq bench

test:
	JQ=$(JQ) python3 tests/run_tests.py

# jq has --run-tests; for other implementations (gojq) the runner emulates it
test-jq:
	@if $(JQ) --version | grep -q '^jq-'; then $(JQ) -L . --run-tests tests/parse.test; \
	else JQ=$(JQ) python3 tests/run_tests.py JqTestSuites; fi

bench:
	JQ=$(JQ) python3 tests/run_tests.py --bench
