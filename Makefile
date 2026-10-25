PYTHON ?= python3
VENV_PYTHON := .venv/bin/python
SWIFT_CONFIGURATION ?= debug
APP_ARGS ?=

.PHONY: setup check test-receiver test-macos test build-receiver app-debug app

setup:
	$(PYTHON) -m venv .venv
	$(VENV_PYTHON) -m pip install -r requirements-dev.txt

check:
	$(VENV_PYTHON) scripts/check.py

test-receiver:
	cd services/receiver && go test -race ./...
	cd services/receiver && go vet ./...

test-macos:
	swift test --package-path apps/macos --configuration $(SWIFT_CONFIGURATION) --arch arm64

test: test-receiver test-macos

build-receiver:
	cd services/receiver && go build -trimpath -o bin/nowbeam-receiver ./cmd/nowbeam-receiver

app-debug:
	$(VENV_PYTHON) scripts/build_macos.py --configuration debug --skip-dmg $(APP_ARGS)

app:
	$(VENV_PYTHON) scripts/build_macos.py --configuration release $(APP_ARGS)
