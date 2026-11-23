#!/bin/sh
# Each *arr app backs off from a failing indexer for longer every time (up to
# 24h), and only a successful indexer test clears that. When the app's health
# reports an indexer in (long-term) backoff, run "test all": a test that passes
# resets the backoff, one that fails changes nothing. Sonarr and Radarr have no
# indexer status endpoint, so all apps use the health checks.
#
# The app's config is mounted read-only at /app-config; its config.xml gives
# the API key and port, so the sidecar needs no secret or per-app settings.
# Sonarr and Radarr serve API v3, Prowlarr v1.
set -u
interval=${INTERVAL_SECONDS:-900}
log() { echo "$(date -u +%FT%TZ) $*"; }
setting() { sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" /app-config/config.xml; }
sleep 300
while true; do
  key=$(setting ApiKey)
  port=$(setting Port)
  health=""
  for version in v3 v1; do
    api="http://localhost:${port}/api/${version}"
    health=$(curl -fsS -m 30 -H "X-Api-Key: ${key}" "${api}/health" 2>/dev/null) && break
    health=""
  done
  if [ -z "$health" ]; then
    log "could not read health"
  elif echo "$health" | grep -Eq '"source": *"Indexer(LongTerm)?StatusCheck"'; then
    log "indexer in backoff, testing all indexers"
    result=$(curl -sS -m 600 -X POST -H "X-Api-Key: ${key}" "${api}/indexer/testall")
    log "testall passed=$(echo "$result" | grep -Eo '"isValid": *true' | wc -l)" \
      "failed=$(echo "$result" | grep -Eo '"isValid": *false' | wc -l)"
  fi
  sleep "$interval"
done
