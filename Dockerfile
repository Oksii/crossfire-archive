FROM nginx:1.30-alpine

# 7zip provides `7z`; curl is used for the download and the healthcheck.
RUN apk add --no-cache 7zip curl

ENV SITE_ROOT=/site \
    ARCHIVE_URL=https://dl.etl.lol/crossfire-archive.7z \
    ARCHIVE_SHA256=07e1d4541ba01cd0e332c791b80c54f640dbba5de4f518efc1c1b7d82cf0f771 \
    MIN_FREE_GIB=18

# preparing.conf is what's live at boot; the entrypoint swaps site.conf in
# once the archive is unpacked.
COPY nginx/preparing.conf /etc/nginx/conf.d/default.conf
COPY nginx/site.conf      /etc/nginx/crossfire-site.conf
COPY nginx/preparing.html /usr/share/nginx/preparing/503.html
COPY entrypoint.sh        /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/site"]
EXPOSE 80

# The holding page answers 503, which fails `curl -f`, so the container reads
# `health: starting` for as long as extraction takes and `healthy` after.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40m --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
