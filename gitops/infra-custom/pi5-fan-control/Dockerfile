# syntax=docker/dockerfile:1.28

# renovate: datasource=docker depName=golang
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.24@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS build

ARG TARGETOS=linux
ARG TARGETARCH=arm64

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -buildid=" \
    -o /out/pi5-fan-control ./cmd/pi5-fan-control

FROM scratch

COPY --from=build /out/pi5-fan-control /pi5-fan-control

USER 0
ENTRYPOINT ["/pi5-fan-control"]
