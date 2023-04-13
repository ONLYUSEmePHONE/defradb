# Make DefraDB!
# For compatibility, prerequisites are instead explicit calls to make.

ifndef VERBOSE
MAKEFLAGS+=--no-print-directory
endif

# Provide info from git to the version package using linker flags.
ifeq (, $(shell which git))
$(error "No git in $(PATH), version information won't be included")
else
VERSION_GOINFO=$(shell go version)
VERSION_GITCOMMIT=$(shell git rev-parse HEAD)
VERSION_GITCOMMITDATE=$(shell git show -s --format=%cs HEAD)
ifneq ($(shell git symbolic-ref -q --short HEAD),master)
VERSION_GITRELEASE=dev-$(shell git symbolic-ref -q --short HEAD)
else
VERSION_GITRELEASE=$(shell git describe --tags)
endif

BUILD_FLAGS=-trimpath -ldflags "\
-X 'github.com/sourcenetwork/defradb/version.GoInfo=$(VERSION_GOINFO)'\
-X 'github.com/sourcenetwork/defradb/version.GitRelease=$(VERSION_GITRELEASE)'\
-X 'github.com/sourcenetwork/defradb/version.GitCommit=$(VERSION_GITCOMMIT)'\
-X 'github.com/sourcenetwork/defradb/version.GitCommitDate=$(VERSION_GITCOMMITDATE)'"
endif

default:
	@go run $(BUILD_FLAGS) cmd/defradb/main.go

.PHONY: install
install:
	@go install $(BUILD_FLAGS) ./cmd/defradb

# Usage:
# 	- make build
# 	- make build path="path/to/defradb-binary"
.PHONY: build
build:
ifeq ($(path),)
	@go build $(BUILD_FLAGS) -o build/defradb cmd/defradb/main.go
else
	@go build $(BUILD_FLAGS) -o $(path) cmd/defradb/main.go
endif

# Usage: make cross-build platforms="{platforms}"
# platforms is specified as a comma-separated list with no whitespace, e.g. "linux/amd64,linux/arm,linux/arm64"
# If none is specified, build for all platforms.
.PHONY: cross-build
cross-build:
	bash tools/scripts/cross-build.sh $(platforms)

.PHONY: start
start:
	@$(MAKE) build
	./build/defradb start

.PHONY: client\:dump
client\:dump:
	./build/defradb client dump

.PHONY: client\:add-schema
client\:add-schema:
	./build/defradb client schema add -f examples/schema/bookauthpub.graphql

.PHONY: deps\:lint
deps\:lint:
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.51

.PHONY: deps\:test
deps\:test:
	go install gotest.tools/gotestsum@latest

.PHONY: deps\:coverage
deps\:coverage:
	go install github.com/ory/go-acc@latest

.PHONY: deps\:bench
deps\:bench:
	go install golang.org/x/perf/cmd/benchstat@latest

.PHONY: deps\:chglog
deps\:chglog:
	go install github.com/git-chglog/git-chglog/cmd/git-chglog@latest

.PHONY: deps\:modules
deps\:modules:
	go mod download

.PHONY: deps
deps:
	@$(MAKE) deps:modules && \
	$(MAKE) deps:bench && \
	$(MAKE) deps:chglog && \
	$(MAKE) deps:coverage && \
	$(MAKE) deps:lint && \
	$(MAKE) deps:test

.PHONY: dev\:start
dev\:start:
	@$(MAKE) build
	DEFRA_ENV=dev ./build/defradb start

# Note: In some situations `verify` can modify `go.sum` file, but until a
#       read-only version is available we have to rely on this.
# Here are some relevant issues:
#   - https://github.com/golang/go/issues/31372
#   - https://github.com/cosmos/cosmos-sdk/issues/4165
.PHONY: verify
verify:
	@if go mod verify | grep -q 'all modules verified'; then \
		echo "Success!";                                     \
	else                                                     \
		echo "Failure:";                                     \
		go mod verify;                                       \
		exit 2;                                              \
	fi;

.PHONY: tidy
tidy:
	go mod tidy -go=1.19

.PHONY: clean
clean:
	go clean cmd/defradb/main.go
	rm -f build/defradb

.PHONY: clean\:test
clean\:test:
	go clean -testcache

# Example: `make tls-certs path="~/.defradb/certs"`
.PHONY: tls-certs
tls-certs:
ifeq ($(path),)
	openssl ecparam -genkey -name secp384r1 -out server.key
	openssl req -new -x509 -sha256 -key server.key -out server.crt -days 365
else
	mkdir -p $(path)
	openssl ecparam -genkey -name secp384r1 -out $(path)/server.key
	openssl req -new -x509 -sha256 -key $(path)/server.key -out $(path)/server.crt -days 365
endif

.PHONY: test
test:
	gotestsum --format pkgname -- ./... -race -shuffle=on

# Only build the tests (don't execute them).
.PHONY: test\:build
test\:build:
	gotestsum --format pkgname -- ./... -race -shuffle=on -run=nope

.PHONY: test\:ci
test\:ci:
	DEFRA_BADGER_MEMORY=true DEFRA_BADGER_FILE=true $(MAKE) test:names

.PHONY: test\:go
test\:go:
	go test ./... -race -shuffle=on

.PHONY: test\:names
test\:names:
	gotestsum --format testname -- ./... -race -shuffle=on

.PHONY: test\:verbose
test\:verbose:
	gotestsum --format standard-verbose -- ./... -race -shuffle=on

.PHONY: test\:watch
test\:watch:
	gotestsum --watch -- ./...

.PHONY: test\:clean
test\:clean:
	@$(MAKE) clean:test && $(MAKE) test

.PHONY: test\:bench
test\:bench:
	@$(MAKE) -C ./tests/bench/ bench

.PHONY: test\:bench-short
test\:bench-short:
	@$(MAKE) -C ./tests/bench/ bench:short

.PHONY: test\:scripts
test\:scripts:
	@$(MAKE) -C ./tools/scripts/ test

# Using go-acc to ensure integration tests are included.
# Usage: `make test:coverage` or `make test:coverage path="{pathToPackage}"`
# Example: `make test:coverage path="./api/..."`
.PHONY: test\:coverage
test\:coverage:
	@$(MAKE) deps:coverage
ifeq ($(path),)
	go-acc ./... --output=coverage.txt --covermode=atomic -- -coverpkg=./...
	@echo "Show coverage information for each function in ./..."
else
	go-acc $(path) --output=coverage.txt --covermode=atomic -- -coverpkg=$(path)
	@echo "Show coverage information for each function in" path=$(path)
endif
	go tool cover -func coverage.txt | grep total | awk '{print $$3}'

# Usage: `make test:coverage-html` or `make test:coverage-html path="{pathToPackage}"`
# Example: `make test:coverage-html path="./api/..."`
.PHONY: test\:coverage-html
test\:coverage-html:
	@$(MAKE) test:coverage path=$(path)
	@echo "Generate coverage information in HTML"
	go tool cover -html=coverage.txt
	rm ./coverage.txt

.PHONY: test\:changes
test\:changes:
	env DEFRA_DETECT_DATABASE_CHANGES=true gotestsum -- ./... -shuffle=on -p 1

.PHONY: validate\:codecov
validate\:codecov:
	curl --data-binary @.github/codecov.yml https://codecov.io/validate

.PHONY: validate\:circleci
validate\:circleci:
	circleci config validate

.PHONY: lint
lint:
	golangci-lint run --config tools/configs/golangci.yaml

.PHONY: lint\:fix
lint\:fix:
	golangci-lint run --config tools/configs/golangci.yaml --fix

.PHONY: lint\:todo
lint\:todo:
	rg "nolint" -g '!{Makefile}'

.PHONY: lint\:list
lint\:list:
	golangci-lint linters --config tools/configs/golangci.yaml

.PHONY: chglog
chglog:
	git-chglog -c "tools/configs/chglog/config.yml" --next-tag v0.x.0 -o CHANGELOG.md

.PHONY: docs
docs:
	@$(MAKE) docs\:cli
	@$(MAKE) docs\:manpages

.PHONY: docs\:cli
docs\:cli:
	go run cmd/genclidocs/genclidocs.go -o docs/cli/

.PHONY: docs\:manpages
docs\:manpages:
	go run cmd/genmanpages/main.go -o build/man/

.PHONY: docs\:godoc
docs\:godoc:
	godoc -http=:6060
	# open http://localhost:6060/pkg/github.com/sourcenetwork/defradb/

detectedOS := $(shell uname)
.PHONY: install\:manpages
install\:manpages:
ifeq ($(detectedOS),Linux)
	cp build/man/* /usr/share/man/man1/
endif
ifneq ($(detectedOS),Linux)
	@echo "Direct installation of Defradb's man pages is not supported on your system."
endif