## Multi-stage build for a static cronlord binary.
## Stage 1 builds on Alpine with Crystal; stage 2 ships only the binary and
## runtime assets (views + public CSS) on a minimal base.

FROM crystallang/crystal:1.19-alpine AS build

## Static link needs the -static archives for every lib crystal-sqlite3
## and kemal pull in. The base image only ships the shared builds.
RUN apk add --no-cache \
      sqlite-static \
      sqlite-dev \
      openssl-dev \
      openssl-libs-static \
      pcre2-dev \
      zlib-static \
      gc-dev

WORKDIR /src

## Copy shard manifests first so the dependency fetch caches across code edits.
COPY shard.yml shard.lock ./
RUN shards install --production

COPY src ./src
COPY db ./db
COPY spec ./spec

## Build a fully static binary so the runtime stage doesn't need libc.
RUN shards build cronlord --production --release --static --no-debug

## ---- runtime ---------------------------------------------------------------

FROM alpine:3.20 AS runtime

RUN addgroup -S cronlord && adduser -S -G cronlord -H -s /sbin/nologin cronlord \
 && apk add --no-cache tini ca-certificates tzdata

WORKDIR /app
COPY --from=build /src/bin/cronlord /usr/local/bin/cronlord
COPY --from=build /src/src/cronlord/views ./src/cronlord/views
COPY --from=build /src/public ./public
COPY --from=build /src/db ./db

## Default location for data (db + logs). Mount a volume here in prod.
RUN mkdir -p /var/lib/cronlord && chown -R cronlord:cronlord /var/lib/cronlord /app
VOLUME ["/var/lib/cronlord"]

ENV CRONLORD_HOST=0.0.0.0 \
    CRONLORD_PORT=7070 \
    CRONLORD_DATA=/var/lib/cronlord

USER cronlord
EXPOSE 7070

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:7070/healthz >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/cronlord"]
CMD ["server"]
