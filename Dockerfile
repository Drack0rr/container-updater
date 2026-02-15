# syntax=docker/dockerfile:1.7
FROM alpine:3.21 AS runtime

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    docker-cli \
    docker-cli-compose \
    jq \
    tzdata

WORKDIR /app
COPY container-updater.sh /app/container-updater.sh

RUN chmod +x /app/container-updater.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD /app/container-updater.sh --healthcheck || exit 1

ENTRYPOINT ["/app/container-updater.sh"]
