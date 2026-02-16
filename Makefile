SHELL := /bin/bash

.PHONY: help build test clean

help:
	@printf "%s\n" \
		"make build   - universal release build into bin/" \
		"make test    - run swift test" \
		"make clean   - swift package clean"

test:
	swift test

build:
	swift package resolve
	scripts/build-universal.sh

clean:
	swift package clean
