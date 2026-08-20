#!/bin/sh
#
# Crossfire archive container entrypoint.
#
#   1. If the volume already holds a good extraction, serve it immediately.
#   2. Otherwise bring nginx up on a 503 holding page, then download / verify /
#      extract in the foreground, swap in the real config and reload.
#   3. Any failure kills nginx and exits non-zero, so restart policies retry.
#
set -eu

SITE_ROOT="${SITE_ROOT:-/site}"
ARCHIVE_URL="${ARCHIVE_URL:-}"
ARCHIVE_SHA256="${ARCHIVE_SHA256:-}"
ARCHIVE_FILE="${ARCHIVE_FILE:-}"
KEEP_ARCHIVE="${KEEP_ARCHIVE:-0}"
SKIP_DISK_CHECK="${SKIP_DISK_CHECK:-0}"
FORCE_REEXTRACT="${FORCE_REEXTRACT:-0}"
MIN_FREE_GIB="${MIN_FREE_GIB:-18}"

DOCROOT="$SITE_ROOT/raw"
STAGING="$SITE_ROOT/.staging"
SENTINEL="$SITE_ROOT/.extracted"
DOWNLOAD="$SITE_ROOT/archive.7z"

LIVE_CONF=/etc/nginx/conf.d/default.conf
SITE_CONF=/etc/nginx/crossfire-site.conf

# Sections whose pages are stored as <id>.<slug>.html and therefore need
# <id>.html aliases for /section/view/id/N to resolve. `group`, `user` and
# `articlepages` already use bare ids and are deliberately absent.
ID_SECTIONS="journals news articles tutorials videos polls"

NGINX_PID=""

log() { printf '[crossfire] %s\n' "$*"; }

die() {
    printf '[crossfire] ERROR: %s\n' "$*" >&2
    if [ -n "$NGINX_PID" ]; then
        log "stopping nginx so the container exits non-zero"
        kill "$NGINX_PID" 2>/dev/null || true
        wait "$NGINX_PID" 2>/dev/null || true
    fi
    exit 1
}

on_signal() {
    log "signal received, shutting down"
    [ -n "$NGINX_PID" ] && kill -QUIT "$NGINX_PID" 2>/dev/null || true
    exit 0
}
trap on_signal TERM INT

# The digest we expect this volume to have been built from. An empty
# ARCHIVE_SHA256 means the operator opted out of verification.
expected_digest() {
    if [ -n "$ARCHIVE_SHA256" ]; then printf '%s' "$ARCHIVE_SHA256"
    else printf 'unverified'; fi
}

# ---------------------------------------------------------------------------

check_digest_drift() {
    [ -f "$SENTINEL" ] || return 0

    stored="$(cat "$SENTINEL" 2>/dev/null || true)"
    expected="$(expected_digest)"
    [ "$stored" = "$expected" ] && return 0

    if [ "$FORCE_REEXTRACT" = "1" ]; then
        log "digest drift, FORCE_REEXTRACT=1 — discarding the existing extraction"
        rm -rf "$DOCROOT" "$SENTINEL"
        return 0
    fi

    cat >&2 <<EOF
[crossfire] ERROR: this volume was extracted from a different archive.

    stored in volume : $stored
    expected now     : $expected

Refusing to start rather than silently serving content that doesn't match the
configured archive, or destroying ~16 GiB of extracted data without being asked.

Either point ARCHIVE_SHA256/ARCHIVE_URL back at the original archive, or wipe
the volume, or re-run with FORCE_REEXTRACT=1 to discard and re-extract.
EOF
    exit 1
}

check_disk() {
    if [ "$SKIP_DISK_CHECK" = "1" ]; then
        log "disk space check skipped (SKIP_DISK_CHECK=1)"
        return 0
    fi

    free_kib="$(df -Pk "$SITE_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
    case "${free_kib:-}" in
        ''|*[!0-9]*)
            log "WARNING: could not determine free space on $SITE_ROOT, continuing"
            return 0
            ;;
    esac

    need_kib=$((MIN_FREE_GIB * 1024 * 1024))
    if [ "$free_kib" -lt "$need_kib" ]; then
        die "not enough free space on $SITE_ROOT: $((free_kib / 1048576)) GiB available, ${MIN_FREE_GIB} GiB required.
       The archive unpacks to ~16.4 GiB across ~336,000 files.
       Set SKIP_DISK_CHECK=1 if df is misreporting (overlay/network/VM volumes)."
    fi
    log "disk check ok — $((free_kib / 1048576)) GiB free on $SITE_ROOT"
}

verify_digest() {
    # verify_digest <file> [quiet]  -> 0 if it matches (or verification is off)
    file="$1"
    if [ -z "$ARCHIVE_SHA256" ]; then
        [ "${2:-}" = "quiet" ] || log "WARNING: ARCHIVE_SHA256 is empty, skipping verification"
        return 0
    fi
    printf '%s  %s\n' "$ARCHIVE_SHA256" "$file" | sha256sum -c - >/dev/null 2>&1
}

fetch_archive() {
    if [ -n "$ARCHIVE_FILE" ]; then
        [ -r "$ARCHIVE_FILE" ] || die "ARCHIVE_FILE=$ARCHIVE_FILE is not readable"
        log "using local archive $ARCHIVE_FILE (no download)"
        verify_digest "$ARCHIVE_FILE" \
            || die "checksum mismatch on $ARCHIVE_FILE (expected $ARCHIVE_SHA256)"
        SOURCE="$ARCHIVE_FILE"
        SOURCE_IS_LOCAL=1
        return 0
    fi

    [ -n "$ARCHIVE_URL" ] || die "neither ARCHIVE_URL nor ARCHIVE_FILE is set"
    SOURCE="$DOWNLOAD"
    SOURCE_IS_LOCAL=0

    if [ -f "$DOWNLOAD" ] && verify_digest "$DOWNLOAD" quiet; then
        log "reusing already-downloaded archive at $DOWNLOAD"
        return 0
    fi
    rm -f "$DOWNLOAD"

    log "downloading $ARCHIVE_URL (~357 MiB)"
    curl -fL --retry 3 --retry-delay 5 --retry-all-errors \
         --connect-timeout 30 -o "$DOWNLOAD" "$ARCHIVE_URL" \
        || die "download failed after retries: $ARCHIVE_URL"

    verify_digest "$DOWNLOAD" \
        || die "checksum mismatch on the downloaded archive.
       expected $ARCHIVE_SHA256
       got      $(sha256sum "$DOWNLOAD" | awk '{print $1}')
       The file at $ARCHIVE_URL is not the archive this image expects.
       Set ARCHIVE_SHA256 to the new digest, or to an empty string to skip this check."
    log "download verified"
}

# /news/1.html -> 1.some-slug.html, one alias per page, so the archive's own
# `/section/view/id/N` rewrite resolves. See DEVIATION (A) in nginx/site.conf.
make_id_aliases() {
    root="$1"
    pairs="$STAGING/.idlinks"
    : > "$pairs"

    for section in $ID_SECTIONS; do
        dir="$root/$section"
        [ -d "$dir" ] || continue
        ls -1 "$dir" 2>/dev/null \
            | grep -E '^[0-9]+\..*\.html$' \
            | grep -vE '^[0-9]+\.page\.[0-9]+\.html$' \
            | sort \
            | awk -v d="$dir" '
                { id = $0; sub(/\..*$/, "", id)
                  if (id in seen) next          # first slug wins, deterministically
                  seen[id] = 1
                  printf "%s\n%s/%s.html\n", $0, d, id }' >> "$pairs"
    done

    count=$(( $(wc -l < "$pairs") / 2 ))
    if [ "$count" -eq 0 ]; then
        rm -f "$pairs"
        log "no <id>.html aliases needed"
        return 0
    fi

    log "creating $count <id>.html aliases"
    # One ln per link is ~0.5 ms; at this volume that's worth splitting across
    # a few workers. Chunks are an even number of lines so pairs stay intact.
    rm -f "$STAGING"/.idl.*
    split -l 40000 "$pairs" "$STAGING/.idl."
    workers=""
    for chunk in "$STAGING"/.idl.*; do
        xargs -n 2 ln -sfn < "$chunk" &
        workers="$workers $!"
    done
    # Wait on these PIDs specifically. A bare `wait` would also block on the
    # background nginx, which never exits.
    for w in $workers; do
        wait "$w" || log "WARNING: an alias worker reported errors"
    done
    rm -f "$pairs" "$STAGING"/.idl.*
}

prepare() {
    rm -rf "$STAGING"          # wipe anything left by an aborted run
    mkdir -p "$STAGING"

    check_disk
    fetch_archive

    log "extracting $(du -h "$SOURCE" 2>/dev/null | cut -f1) from $SOURCE"
    7z x -y -bso0 -bsp0 -o"$STAGING" "$SOURCE" >/dev/null \
        || die "extraction failed"
    [ -d "$STAGING/raw" ] || die "archive has no top-level raw/ directory"

    make_id_aliases "$STAGING/raw"

    # Rename within one filesystem: atomic and instant, so $DOCROOT never
    # exists in a half-built state.
    mv "$STAGING/raw" "$DOCROOT"
    rmdir "$STAGING" 2>/dev/null || true

    expected_digest > "$SENTINEL"

    if [ "$SOURCE_IS_LOCAL" = "0" ] && [ "$KEEP_ARCHIVE" != "1" ]; then
        rm -f "$DOWNLOAD"
        log "removed the downloaded archive (KEEP_ARCHIVE=1 to retain it)"
    fi

    log "extraction complete"
}

# Block until the background nginx is actually serving. Polls the socket rather
# than the pid file: it proves a worker is accepting connections, and it fails
# fast and loudly if nginx died on a bad config instead of hanging.
wait_for_nginx() {
    for _ in $(seq 1 100); do
        kill -0 "$NGINX_PID" 2>/dev/null || die "nginx exited during startup"
        # Any HTTP response will do here -- the holding page answers 503, so
        # -f would reject exactly the reply we're waiting for.
        if curl -s -o /dev/null --max-time 2 http://127.0.0.1/ 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    die "nginx did not start listening within 10s"
}

# ---------------------------------------------------------------------------

main() {
    [ "$#" -gt 0 ] && exec "$@"     # escape hatch: `docker run … sh`

    mkdir -p "$SITE_ROOT"
    check_digest_drift

    if [ -f "$SENTINEL" ] && [ -d "$DOCROOT" ]; then
        log "archive already extracted — serving immediately"
        cp "$SITE_CONF" "$LIVE_CONF"
        exec nginx -g 'daemon off;'
    fi

    log "no extracted archive in $SITE_ROOT — serving the holding page while we prepare"
    nginx -g 'daemon off;' &
    NGINX_PID=$!
    wait_for_nginx

    prepare

    cp "$SITE_CONF" "$LIVE_CONF"
    nginx -t >/dev/null 2>&1 || { nginx -t || true; die "the site config failed to validate"; }

    # Signal the master directly instead of `nginx -s reload`. That command
    # reads /run/nginx.pid to find the master, which is a file we neither need
    # nor can rely on having been written yet -- with a small archive, prepare
    # can finish before nginx has got that far.
    kill -HUP "$NGINX_PID" || die "could not signal nginx to reload"
    log "site is live"

    wait "$NGINX_PID"
}

main "$@"
