# crossfire-archive

A Docker image that serves a static mirror of **Crossfire** — `crossfire.nu`,
"Crossfire - A Gaming Community" — the long-running community and esports news
site for competitive **Wolfenstein: Enemy Territory**.

The container downloads a 357 MiB `.7z` of the crawled site, unpacks it, and serves
it over HTTP with the original URL scheme intact, so links like
`/news/view/id/1234` and `/forums/view/id/56/page/3` resolve the way they did on the
live site.

This is a **frozen snapshot**, captured in early 2023. Nothing is dynamic: there are
no logins, no posting, no search, no working forms. Pages render, links work,
everything else is inert.

## Quick start

```sh
docker compose up -d
# then open http://localhost:8080
```

Or without compose:

```sh
docker run -d --name crossfire \
  -p 8080:80 \
  -v crossfire-data:/site \
  --restart unless-stopped \
  ghcr.io/oksii/crossfire-archive:latest
```

> **First boot takes a few minutes** — about 2 on a fast NVMe, longer on slower
> disks. It downloads 357 MiB, unpacks **16.4 GiB across ~336,000 files**, then
> creates ~125,000 symlinks (see
> [URL fidelity](#url-fidelity)). While that runs, the site answers every request
> with `503` and a "preparing" page rather than refusing connections, and the
> container reports `health: starting`. Watch progress with `docker logs -f crossfire`.
>
> This happens **once**. Restarts serve immediately as long as the volume survives.

## Requirements

- **~18 GiB free disk** for the volume (~16.4 GiB steady state). The container checks
  this before downloading and refuses to start if it's short.
- Use a **named volume**, not a bind mount. Unpacking 336k small files through
  Docker Desktop's virtiofs or over NFS is dramatically slower than a native volume.

## Running from a local archive

If you already have the `.7z`, or you're offline, skip the download entirely:

```sh
docker run -d --name crossfire \
  -p 8080:80 \
  -v crossfire-data:/site \
  -v "$PWD/crossfire-archive.7z:/archive.7z:ro" \
  -e ARCHIVE_FILE=/archive.7z \
  ghcr.io/oksii/crossfire-archive:latest
```

The checksum is still verified unless you clear `ARCHIVE_SHA256`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ARCHIVE_URL` | `https://dl.etl.lol/crossfire-archive.7z` | Where to fetch the archive. |
| `ARCHIVE_SHA256` | `07e1d454…f0f771` | Expected SHA-256. Set to `""` to skip verification. |
| `ARCHIVE_FILE` | *(unset)* | Path to a local `.7z`. If set and readable, no download happens. |
| `KEEP_ARCHIVE` | `0` | `1` keeps the downloaded `.7z` in the volume (+357 MiB) instead of deleting it after extraction. |
| `SKIP_DISK_CHECK` | `0` | `1` bypasses the free-space check, for setups where `df` misreports. |
| `FORCE_REEXTRACT` | `0` | `1` discards an existing extraction that came from a different archive and rebuilds it. |
| `MIN_FREE_GIB` | `18` | Free space required before downloading. |
| `SITE_ROOT` | `/site` | Volume mount point. |

## How it works

```
start
  |
  +-- volume already extracted, digest matches?  --> serve immediately
  |
  +-- otherwise:
        nginx comes up on a 503 "preparing" page
        check free disk space
        download (curl --retry 3) or use ARCHIVE_FILE
        verify SHA-256
        extract to /site/.staging
        create ~125k <id>.html aliases
        mv /site/.staging/raw -> /site/raw     (atomic rename)
        write /site/.extracted                 (records the source digest)
        swap in the real config, nginx -s reload
```

**Crash safety.** Extraction happens in `/site/.staging` and only becomes `/site/raw`
via a rename, which is atomic within the volume. `/site/raw` therefore never exists
half-built. A container killed mid-extract wipes the stale staging directory and
starts over on the next boot.

**Failures are loud.** A bad URL or a checksum mismatch stops nginx and exits
non-zero, so `--restart` policies retry with backoff. Transient network blips are
absorbed by `curl --retry` first.

**Digest drift.** `/site/.extracted` records which archive the volume was built from.
If that stops matching `ARCHIVE_SHA256`, the container refuses to start and prints
both digests — rather than silently serving stale content, or deleting 16 GiB because
an environment variable changed. `FORCE_REEXTRACT=1` opts into the rebuild.

## URL fidelity

The archive ships its own nginx config at `raw/nginx-rules.txt` — the ruleset the
mirror was originally built against, mapping the live site's URLs onto the flat
filenames the crawler wrote:

| Original URL | File |
|---|---|
| `/news/view/id/1234` | `news/1234.thread-slug.html` |
| `/journals/index/page/4` | `journals/index.page.4.html` |
| `/articles/view/id/5/page/2` | `articles/5.page.2.html` |
| `/forums/view/id/56/page/3` | `forums/view.id.56.page.3.html` |
| `/user/view/id/99/tab/activity` | `user/99.tab.activity.html` |

`nginx/site.conf` reproduces those rules, with the `root` repointed and two
deliberate fixes:

**A. `<id>.html` aliases.** The original rule rewrites `/news/view/id/1` to
`/news/1.html`, but no such file exists — outside of `group`, `user` and
`articlepages`, every page is stored as `<id>.<slug>.html`. As shipped, that rule
404s for roughly **124,900 pages**: every news post, journal, article, tutorial,
video and poll. The original author knew, leaving the note
`# todo, fix these, change filenames to just ids` in the config. Rather than change
the rule, the entrypoint creates one `<id>.html` symlink per page after extraction,
so it resolves as written.

**B. Forum pagination.** The original listed the unanchored
`^/forums/view/id/(\d+)` rule *before* its `/page/(\d+)` variant, so
`/forums/view/id/9/page/2` matched the first one and was rewritten to page 1 —
stranding the **438** forum pages numbered 2 or higher that exist in the archive.
The two lines are swapped here. No previously-working URL changes behaviour.

Both are marked `DEVIATION` in `nginx/site.conf`, and both are covered by the CI
smoke test.

## Archive

| | |
|---|---|
| Size | 373,820,624 bytes (357 MiB) compressed, 17,641,044,232 bytes (16.4 GiB) extracted |
| Contents | 336,182 files in 33 folders, all under a top-level `raw/` |
| SHA-256 | `07e1d4541ba01cd0e332c791b80c54f640dbba5de4f518efc1c1b7d82cf0f771` |
| Crawled | January–May 2023; archive sealed 2024-02-05 |

Largest sections: `journals` (145k files), `news` (44k), `user` (39k), `threads`
(32k), `articles` (22k), `polls` (20k), `tutorials` (20k).

## CI

`.github/workflows/docker.yml` builds on every push and pull request, and pushes to
GHCR on every push (`latest` on the default branch, plus a short-SHA tag and a branch
tag) for `linux/amd64` and `linux/arm64`.

CI can't pull 16 GiB, so the push is gated on a smoke test that runs the container
against a ~2 KB stand-in archive built in the same layout. It asserts the container
reaches `healthy`, that the rewrites and `<id>.html` aliases resolve, that
`error_page 404` serves the archive's own 404 page, that a restart takes the
already-extracted fast path, and that a bad checksum exits non-zero.

> Packages are private by default. If others should be able to pull the image, make
> it public under the repository's *Packages* settings.

## Licence

The container tooling here is yours to do as you like with. The archived site content
belongs to Crossfire and its contributors; this repository does not redistribute it,
it only fetches what's already hosted at `dl.etl.lol`.
