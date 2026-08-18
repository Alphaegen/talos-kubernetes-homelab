# syntax=docker/dockerfile:1.26

# renovate: datasource=docker depName=golang
FROM --platform=$BUILDPLATFORM golang:1.26.6-alpine3.24@sha256:3889b425f035be855a72fb4755265311293b6d414521f0a519d819df32222d83 AS build

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
