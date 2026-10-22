ODIN ?= odin
BIN  ?= ctxdb
PYTHON ?= python3

.PHONY: build test check clean

build:
	$(ODIN) build . -out:$(BIN)

test: build
	$(PYTHON) scripts/smoke.py --binary ./$(BIN)

check:
	$(ODIN) check . -vet

clean:
	rm -f $(BIN)
