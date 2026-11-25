# check=skip=InvalidDefaultArgInFrom
# guacd with a time-zone database.
#
# The upstream guacd image ships no time-zone database (no /usr/share/zoneinfo),
# so every requested zone silently runs as UTC. This image adds exactly one
# layer on top of the pinned upstream image: the Alpine `tzdata` package.
# Remove this repository's image when upstream ships a time-zone database.
#
# BASE and TZDATA_VERSION have no defaults: scripts/build-guacd-image supplies
# them (BASE from the BASE file, TZDATA_VERSION probed from the package index).

ARG BASE

# Probe stage: only used by scripts/build-guacd-image to learn which tzdata
# version apk installs. It is not part of the final image.
FROM ${BASE} AS probe
USER root
RUN apk add --no-cache tzdata

FROM ${BASE}
ARG BASE
ARG BASE_DIGEST
ARG TZDATA_VERSION
ARG REVISION
ARG CREATED
ARG RUN_ID
USER root
RUN apk add --no-cache "tzdata=${TZDATA_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/msadeem/guacd-tzdata" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.base.name="${BASE}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      guacd-tzdata.tzdata-version="tzdata-${TZDATA_VERSION}" \
      guacd-tzdata.workflow-run-id="${RUN_ID}"
USER guacd
