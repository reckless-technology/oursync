# OurSync build wrapper.
#
# Plain Go 1.26.x — no build tags, no experiments, no cgo. The FUSE layer talks to /dev/fuse
# directly through go-fuse and the SQLite driver is pure Go, so `go build` needs no C compiler and
# cross-compiles cleanly. That is deliberate: it is what keeps the .deb to one binary.
#
# Everything built lands under build/, which .gitignore covers (the house rule — a build tree
# beside it is what puts 2,814 files into an index).
#
# On Windows this builds nothing runnable: the daemon is Linux-only (FUSE). `make vet` and
# `make test` for the platform-independent packages work anywhere; the mount tests are tagged
# `fuse` and run on jonny-precision. See CLAUDE.md.

GO ?= go
PKG := ./...
OUT := build

DAEMON := oursyncd
CLI    := oursync

VERSION := $(shell tools/version.sh)
LDFLAGS := -X github.com/reckless-technology/oursync/internal/build.version=$(VERSION)

# Statement coverage gate. One place the number is written; CI's coverage job runs this target.
COVER_MIN ?= 85

.PHONY: all build test test-short check cover vet fmt fmt-check livetest fusetest clean

all: build

build:
	$(GO) build -ldflags "$(LDFLAGS)" -o $(OUT)/$(DAEMON) ./cmd/$(DAEMON)
	$(GO) build -ldflags "$(LDFLAGS)" -o $(OUT)/$(CLI) ./cmd/$(CLI)
	@echo "built $(OUT)/$(DAEMON) and $(OUT)/$(CLI)  (version $(VERSION))"

test:
	$(GO) test $(PKG)

test-short:
	$(GO) test -short $(PKG)

# The full gate, and what CI runs. `fmt-check` rather than `fmt` so CI reports an unformatted file
# instead of silently rewriting it.
check: fmt-check vet test

cover:
	$(GO) test $(PKG) -coverpkg=$(PKG) -coverprofile=coverage.out
	@$(GO) tool cover -func=coverage.out | awk -v min=$(COVER_MIN) ' \
		/^total:/ { found = 1; total = $$NF; sub(/%/, "", total) } \
		END { \
			if (!found) { print "cover: no total line in go tool cover -func"; exit 1 } \
			printf "total statement coverage %s%% (gate %s%%)\n", total, min; \
			if (total + 0 < min + 0) { printf "cover: %s%% is under the %s%% gate\n", total, min; exit 1 } \
		}'

vet:
	$(GO) vet $(PKG)

# Prove a Linux build from any host. CGO_ENABLED=0 is load-bearing on Windows, where `go env CC`
# may point at a native clang: without it the cross-build tries to compile runtime/cgo and fails on
# a missing grp.h, which looks like a code error and is not one. OurSync uses no cgo anywhere.
crosscheck:
	CGO_ENABLED=0 GOOS=linux $(GO) build $(PKG)
	CGO_ENABLED=0 GOOS=linux $(GO) vet $(PKG)
	@echo "linux build and vet clean"

fmt:
	$(GO) fmt $(PKG)

fmt-check:
	@unformatted=$$(gofmt -l $$(git ls-files '*.go') 2>/dev/null); \
	if [ -n "$$unformatted" ]; then \
		echo "gofmt: these files need formatting (run make fmt):"; \
		printf '  %s\n' $$unformatted; \
		exit 1; \
	fi

# The mount tests. They need /dev/fuse and a real mount, so they never run in CI — run them on
# jonny-precision (Linux, kernel 7.0, fusermount3 present).
fusetest:
	$(GO) test -tags fuse -v ./internal/vfs/... ./internal/cache/...

# The live Drive tests. Jonny's real account, his API quota, never in CI, never unattended.
livetest:
	$(GO) test -tags livetest -v -count=1 ./internal/drive/livetest/...

clean:
	$(GO) clean
	rm -rf $(OUT) coverage.out
