# guacd-tzdata

A small container image: the upstream [`guacamole/guacd`](https://hub.docker.com/r/guacamole/guacd)
image plus the Alpine `tzdata` package.

## Why

The upstream guacd image ships no time-zone database (no `/usr/share/zoneinfo`),
so a requested time zone cannot be applied and every session runs as UTC. This
image adds exactly one layer on top of a pinned upstream image: the `tzdata`
package. Nothing else changes (same user, same entrypoint). When upstream ships a
time-zone database, this image is no longer needed.

## What is in the repository

- `BASE`: the pinned upstream reference (a digest), the only place it is written.
- `Dockerfile`, `scripts/build-guacd-image`: build the image (`linux/amd64` only).
- `scripts/guacd-image-gate`, `scripts/guacd-layer-allowlist`: a gate that reads the
  built image, not the build log: the layers are the base's layers plus one, the added
  layer holds only allowlisted paths, the config is as expected, and a container
  shows the zone database working.
- `tests/guacd-image-gate-test.sh`: the gate's tests (hand-made layers and configs,
  plus a few real-image cases).
- `scripts/check-public-hygiene`, `scripts/deny-patterns`: a scan for content that
  must not appear in a public repository.
- `.github/workflows/ci.yml`: tests, then a build and gate run. It never pushes.
- `.github/workflows/publish.yml`: manual only, `main` only. Builds, runs the gate,
  pushes `ghcr.io/<owner>/guacd-tzdata:sha-<commit>` and attests the digest.

## Using the image

Pin it by digest, never by tag:

    image: ghcr.io/<owner>/guacd-tzdata@sha256:<digest>

Verify where a digest came from (needs the `gh` CLI; no authentication to the
registry is needed for a public package):

    gh attestation verify oci://ghcr.io/<owner>/guacd-tzdata@sha256:<digest> \
      --bundle-from-oci --repo <owner>/guacd-tzdata \
      --signer-workflow <owner>/guacd-tzdata/.github/workflows/publish.yml \
      --source-ref refs/heads/main

## Local build

    scripts/build-guacd-image guacd-tzdata:local
    scripts/guacd-image-gate guacd-tzdata:local "$(cat BASE)"
    tests/guacd-image-gate-test.sh

## Support

This is published as is. There is no support promise.

## License

Apache License 2.0 for the files in this repository (`LICENSE`). See `NOTICE` for the
licenses of what the image contains.
