# syntax=docker/dockerfile:1.27

# renovate: datasource=docker depName=golang
FROM --platform=$BUILDPLATFORM golang:1.27.1-alpine3.24@sha256:cf6fca6641884b8433441b2b0652976f975e1d0fdd26d177eaaf8596087f3125 AS build

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
