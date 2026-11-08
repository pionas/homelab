SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

SH_FILES := $(shell git ls-files --cached --others --exclude-standard -- '*.sh' '*.bats')
CONF_FILES := $(wildcard catalog/*/service.conf tests/fixtures/*/*/service.conf)

.PHONY: lint test golden validate container

lint:
	shellcheck -x $(SH_FILES)
	# service.conf is plain KEY=value data, so unused-variable warnings do not apply
	shellcheck -s bash -e SC2034 $(CONF_FILES)
	shfmt -d -i 2 -ci $(SH_FILES)

test:
	bats tests/unit

golden validate container:
	@echo "make $@: not implemented yet"
