# syntax=docker/dockerfile:1

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/relay .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /out/relay /usr/local/bin/relay

WORKDIR /data
VOLUME /data

# 4100/tcp and 4100/udp (quic-v1) must both be reachable from the internet.
EXPOSE 4100/tcp 4100/udp

ENTRYPOINT ["relay", "-key", "/data/relay.key"]
