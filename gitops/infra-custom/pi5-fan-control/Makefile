GOLANGCI_LINT_VERSION := v2.1.6

.PHONY: test lint build-linux-arm64

test:
	go test ./...

lint:
	go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION) run

build-linux-arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o bin/pi5-fan-control ./cmd/pi5-fan-control
