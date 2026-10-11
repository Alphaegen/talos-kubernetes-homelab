# syntax=docker/dockerfile:1.28

# renovate: datasource=docker depName=golang
FROM --platform=$BUILDPLATFORM golang:1.27.2-alpine3.24@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS build

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
