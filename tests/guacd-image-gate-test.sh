#!/usr/bin/env bash
#
# Tests for scripts/guacd-image-gate, scripts/check-workflows and
# scripts/check-public-hygiene.
#
#   tests/guacd-image-gate-test.sh [--no-docker]
#
# Almost every case is Docker-free: stages 2 and 3 are driven through the gate's
# --check-layer and --check-config seams with hand-made inputs. Only the
# real-image cases (a), (b) and (p) use Docker and need one base pull.
# Every case asserts its own message, not just a non-zero exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/guacd-image-gate"
MAKE="$ROOT/tests/fixtures/make-layer.py"
PARENTS="$ROOT/tests/fixtures/base-parents.tsv"
DOCKER=1
[[ "${1:-}" == "--no-docker" ]] && DOCKER=0

WORK="$(mktemp -d)"
pass=0; fail=0; skipped=0
cleanup() {
  [[ -n "${TAGS:-}" ]] && docker image rm -f $TAGS >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
TAGS=""

ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

# expect_fail <name> <expected message substring> <command...>
expect_fail() {
  local name="$1" want="$2" out rc
  shift 2
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then bad "$name" "exited 0, wanted a failure"
  elif [[ "$out" != *"$want"* ]]; then bad "$name" "message '$out' does not contain '$want'"
  else ok "$name"; fi
}
expect_pass() { # expect_pass <name> <expected substring> <command...>
  local name="$1" want="$2" out rc
  shift 2
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then bad "$name" "exited $rc: $out"
  elif [[ "$out" != *"$want"* ]]; then bad "$name" "output '$out' does not contain '$want'"
  else ok "$name"; fi
}

layer() { python3 "$MAKE" "$WORK/$1.tar" "$1" && echo "$WORK/$1.tar"; }
HINT="is not in scripts/guacd-layer-allowlist; if tzdata changed, re-measure (command in the file header) and review the diff"
BASE_REF="guacamole/guacd@sha256:$(printf '1%.0s' $(seq 64))"

echo "== stage 2: layer content (hand-made layers, no Docker)"
expect_pass "(e3) a clean layer of only allowlisted paths passes" "ok: layer content check" \
  "$GATE" --check-layer "$(layer clean)" "$PARENTS"
expect_fail "(c) an extra file outside the allowlist" "layer content check: usr/local/bin/x $HINT" \
  "$GATE" --check-layer "$(layer outside-file)" "$PARENTS"
expect_fail "(d) a forged apk db does not widen the allowlist" "layer content check: usr/local/bin/x $HINT" \
  "$GATE" --check-layer "$(layer forged-db)" "$PARENTS"
expect_fail "(e) an absolute symlink out of the tree" "usr/share/zoneinfo/Evil is a symlink to /etc/passwd, outside usr/share/zoneinfo/" \
  "$GATE" --check-layer "$(layer sym-abs)" "$PARENTS"
expect_fail "(e) a relative symlink out of the tree" "usr/share/zoneinfo/Asia/Evil is a symlink to ../../../../etc/passwd, outside usr/share/zoneinfo/" \
  "$GATE" --check-layer "$(layer sym-rel)" "$PARENTS"
expect_fail "(e) a whiteout entry" "usr/share/zoneinfo/.wh.UTC is a whiteout entry" \
  "$GATE" --check-layer "$(layer whiteout)" "$PARENTS"
expect_fail "(e) a hard link whose target is outside the tree" "usr/share/zoneinfo/Evil is a hard link to etc/apk/world, outside usr/share/zoneinfo/" \
  "$GATE" --check-layer "$(layer hard-out)" "$PARENTS"
expect_fail "(e2) a zoneinfo file with the executable bit" "usr/share/zoneinfo/Asia/Run has setuid, setgid or executable bits" \
  "$GATE" --check-layer "$(layer exec)" "$PARENTS"
expect_fail "(e2) a zoneinfo file with the setuid bit" "usr/share/zoneinfo/Asia/Su has setuid, setgid or executable bits" \
  "$GATE" --check-layer "$(layer setuid)" "$PARENTS"
expect_fail "(e2) a parent directory with a changed mode" "parent directory etc changed mode/uid/gid compared with the base" \
  "$GATE" --check-layer "$(layer parent-mode)" "$PARENTS"
expect_fail "(e2) a parent directory with a changed owner" "parent directory etc changed mode/uid/gid compared with the base" \
  "$GATE" --check-layer "$(layer parent-uid)" "$PARENTS"
expect_fail "a path with .. components" "$HINT" \
  "$GATE" --check-layer "$(layer traversal)" "$PARENTS"
expect_fail "a bookkeeping path that is a symlink" "etc/apk/world must be a regular file" \
  "$GATE" --check-layer "$(layer book-symlink)" "$PARENTS"
expect_fail "a bookkeeping file with the executable bit" "etc/apk/world has setuid, setgid or executable bits" \
  "$GATE" --check-layer "$(layer book-exec)" "$PARENTS"
expect_fail "a device or fifo entry in the tree" "usr/share/zoneinfo/Fifo has an unsupported entry type" \
  "$GATE" --check-layer "$(layer fifo)" "$PARENTS"
expect_fail "a new directory outside the tree (not a known parent)" "usr/lib $HINT" \
  "$GATE" --check-layer "$(layer parent-unknown)" "$PARENTS"
# an extra pinned by sha256
EXTRA_SHA="$(printf pinned | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
sed -e '/^zoneinfo /!b' "$ROOT/scripts/guacd-layer-allowlist" > "$WORK/allow-extra"
echo "extra usr/share/tzextra.conf $EXTRA_SHA" >> "$WORK/allow-extra"
expect_pass "an extra file pinned by sha256 passes" "ok: layer content check" \
  env GUACD_LAYER_ALLOWLIST="$WORK/allow-extra" "$GATE" --check-layer "$(layer extra-ok)" "$PARENTS"
expect_fail "an extra file whose content differs from its pinned sha256" "usr/share/tzextra.conf does not match the sha256 pinned in scripts/guacd-layer-allowlist" \
  env GUACD_LAYER_ALLOWLIST="$WORK/allow-extra" "$GATE" --check-layer "$(layer extra-bad)" "$PARENTS"
expect_fail "a pinned extra is NOT allowed without its allowlist line" "usr/share/tzextra.conf $HINT" \
  "$GATE" --check-layer "$(layer extra-ok)" "$PARENTS"

echo "== stage 3: config (hand-made JSON, no Docker)"
cfg() { # cfg <file> <user> <entrypoint json> <base label>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
f, user, ep, lab = sys.argv[1:]
json.dump([{"Config": {"User": user, "Entrypoint": json.loads(ep),
  "Labels": {"org.opencontainers.image.base.name": lab}}}], open(f, "w"))
PY
}
cfg "$WORK/base.json" guacd '["/opt/guacamole/entrypoint.sh"]' ""
cfg "$WORK/c-good.json" guacd '["/opt/guacamole/entrypoint.sh"]' "$BASE_REF"
cfg "$WORK/c-root.json" root '["/opt/guacamole/entrypoint.sh"]' "$BASE_REF"
cfg "$WORK/c-ep.json" guacd '["/bin/sh"]' "$BASE_REF"
cfg "$WORK/c-label.json" guacd '["/opt/guacamole/entrypoint.sh"]' "guacamole/guacd@sha256:other"
expect_pass "a good config passes" "ok: config checks" "$GATE" --check-config "$WORK/c-good.json" "$BASE_REF" "$WORK/base.json"
expect_fail "(g) Config.User root" "config check: Config.User is root, expected guacd" "$GATE" --check-config "$WORK/c-root.json" "$BASE_REF" "$WORK/base.json"
expect_fail "a different entrypoint" "config check: Config.Entrypoint" "$GATE" --check-config "$WORK/c-ep.json" "$BASE_REF" "$WORK/base.json"
expect_fail "a wrong base label" "config check: label org.opencontainers.image.base.name is guacamole/guacd@sha256:other" "$GATE" --check-config "$WORK/c-label.json" "$BASE_REF" "$WORK/base.json"

echo "== (f) static policy checks, on the real tree and on mutated copies"
CHECK="$ROOT/scripts/check-workflows"
expect_pass "the real tree satisfies the static checks" "ok: static checks" "$CHECK" "$ROOT"
mutant() { # mutant <name> <file> <old> <new> <expected message>
  local name="$1" file="$2" old="$3" new="$4" want="$5" d="$WORK/mut-$1"
  rm -rf "$d"; mkdir -p "$d"
  (cd "$ROOT" && cp -R .github Dockerfile BASE scripts "$d/")
  python3 - "$d/$file" "$old" "$new" <<'PY' || { bad "(f) $name" "mutation did not apply"; return; }
import sys
f, old, new = sys.argv[1:]
s = open(f).read()
if old not in s:
    sys.exit("pattern not found: " + old)
open(f, "w").write(s.replace(old, new, 1))
PY
  expect_fail "(f) $name" "$want" "$CHECK" "$d"
}
PUB=".github/workflows/publish.yml"
mutant unpinned-action "$PUB" "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" "actions/checkout@v7" "is not pinned by a full 40-hex commit SHA"
mutant extra-permission "$PUB" "      id-token: write" "      id-token: write
      artifact-metadata: write" "job permissions must be exactly"
mutant missing-permission "$PUB" "      attestations: write
" "" "job permissions must be exactly"
mutant missing-storage-input "$PUB" "          create-storage-record: false
" "" "lacks create-storage-record: false"
mutant storage-record-true "$PUB" "create-storage-record: false" "create-storage-record: true" "lacks create-storage-record: false"
mutant missing-push-to-registry "$PUB" "          push-to-registry: true
" "" "lacks push-to-registry: true"
mutant extra-trigger "$PUB" "on:
  workflow_dispatch:" "on:
  push:
  workflow_dispatch:" "triggers must be exactly workflow_dispatch"
mutant target-trigger "$PUB" "on:
  workflow_dispatch:" "on:
  pull_request_target:
  workflow_dispatch:" "uses pull_request_target"
mutant secret-ref "$PUB" "password: \${{ github.token }}" "password: \${{ secrets.EXAMPLE }}" "references secrets.*"
mutant top-permissions "$PUB" "permissions:
  contents: read

concurrency" "permissions:
  contents: write

concurrency" "top-level permissions must be exactly 'contents: read'"
mutant no-main-guard "$PUB" "if: github.ref == 'refs/heads/main'" "if: always()" "no main-only condition"
mutant literal-digest "$PUB" "run: scripts/build-guacd-image" "run: echo sha256:$(printf 'a%.0s' $(seq 64)) && scripts/build-guacd-image" "carries a literal digest"
mutant bad-base BASE "guacamole/guacd@sha256:" "guacamole/guacd:" "BASE is not a guacamole/guacd@sha256:<64 hex> reference"
mutant label-namespace Dockerfile 'guacd-tzdata.workflow-run-id="${RUN_ID}"' 'guacd-tzdata.workflow-run-id="${RUN_ID}" com.example.x="y"' "label keys must be exactly"
mutant label-missing Dockerfile 'guacd-tzdata.workflow-run-id="${RUN_ID}"' 'guacd-tzdata.x="${RUN_ID}"' "label keys must be exactly"
mutant label-subst Dockerfile 'org.opencontainers.image.created="${CREATED}"' 'org.opencontainers.image.created="$(date)"' "neither a literal nor a plain build arg"
mutant tz-env Dockerfile "USER root" "ENV TZ=Asia/Karachi
USER root" "sets a TZ environment variable"
mutant user-root Dockerfile "USER guacd" "USER root" "does not end as USER guacd"

echo "== hygiene scanner (own fail-on-purpose fixtures)"
HYG="$ROOT/scripts/check-public-hygiene"
H="$WORK/hygrepo"
mkdir -p "$H/scripts" && cp "$ROOT/scripts/deny-patterns" "$H/scripts/" && cp "$HYG" "$H/scripts/"
(cd "$H" && git init -q -b main && git config user.name t && git config user.email "1+t@users.noreply.github.com" \
  && echo "clean text" > a.txt && git add -A && git commit -q -m "generic message")
expect_pass "a clean temp repo is clean" "hygiene: clean (0 findings)" "$H/scripts/check-public-hygiene" --repo "$H"
PRIV="$WORK/private-patterns"; echo "zzprivateword" > "$PRIV"
(cd "$H" && printf 'host %s.%s.%s.%s\n' 10 0 0 1 > ip.txt && printf 'mail someone\100example.com\n' > mail.txt \
  && printf 'path %s/%s/name\n' "" "home" > home.txt && printf 'see %s\n' "zzprivateword here" > priv.txt \
  && printf 'time %s %s\n' "10:00" "$(printf 'P%sT' K)" > tz.txt && printf 'finding %s %s-%s\n' "$(printf 'r%s' 12)" "I" "3" > rid.txt \
  && printf 'noreply 5+me@users.noreply.github.com\n' > ok.txt && git add -A && git commit -q -m "plant")
out="$(HYGIENE_EXTRA_PATTERNS_FILE="$PRIV" "$H/scripts/check-public-hygiene" --repo "$H" 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && ok "the scanner exits 1 on planted findings" || bad "the scanner exits 1 on planted findings" "rc=$rc"
for want in "file ip.txt: 1 match(es) of ipv4-address" "file mail.txt: 1 match(es) of non-noreply-email" \
  "file home.txt: 1 match(es) of absolute-home-path" "file priv.txt: 1 match(es) of private-pattern-1" \
  "file tz.txt: 1 match(es) of time-zone-label" "file rid.txt: 1 match(es) of review-id-shape"; do
  [[ "$out" == *"$want"* ]] && ok "scanner reports: $want" || bad "scanner reports: $want" "$out"
done
[[ "$out" != *"zzprivateword"* && "$out" != *"someone@"* ]] && ok "the scanner never prints a matched value" || bad "the scanner never prints a matched value"
[[ "$out" != *"file ok.txt"* ]] && ok "a noreply address is allowed" || bad "a noreply address is allowed"
out="$(cd "$H" && git commit -q --allow-empty -m "$(printf 'fix %s %s-%s' "$(printf 'r%s' 7)" C 1)" && "$H/scripts/check-public-hygiene" --repo "$H" 2>&1)"
[[ "$out" == *"commit "*"match(es) of review-id-shape"* ]] && ok "the scanner reads commit messages" || bad "the scanner reads commit messages" "$out"
out="$(printf 'contact someone\100example.com\n' | "$HYG" --stdin 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"stdin: 1 match(es) of non-noreply-email"* ]] && ok "the scanner reads stdin" || bad "the scanner reads stdin" "$out"
expect_pass "the real repo passes the generic scan" "hygiene: clean (0 findings)" "$HYG" --repo "$ROOT"

echo "== workflow files carry the (p) label rule"
# (p) below relies on a base-name LABEL in its Dockerfile; asserted here so a label rename cannot silently move (p)'s failure point.
P_LABEL='LABEL org.opencontainers.image.base.name='
grep -q "$P_LABEL" "$ROOT/tests/guacd-image-gate-test.sh" && ok "(p) Dockerfile sets the base-name LABEL" || bad "(p) Dockerfile sets the base-name LABEL"

echo "== real-image cases (need Docker and one base pull)"
if [[ $DOCKER -eq 0 ]]; then
  skipped=3; echo "SKIPPED: (a), (b), (p) (--no-docker)"
else
  BASE="$(tr -d '[:space:]' < "$ROOT/BASE")"
  export PLATFORM="${PLATFORM:-linux/amd64}"
  docker pull --platform "$PLATFORM" "$BASE" >/dev/null 2>&1 || { bad "pull the base"; }
  expect_fail "(a) the upstream base itself fails at the parent proof" "parent proof: expected exactly one added layer" "$GATE" "$BASE" "$BASE"
  CTX="$WORK/ctxb"; mkdir -p "$CTX"
  printf 'FROM %s\nUSER root\n' "$BASE" > "$CTX/Dockerfile"
  docker buildx build --platform "$PLATFORM" --provenance=false --sbom=false --load -q -t "gtz-test-b:$$" "$CTX" >/dev/null 2>&1; TAGS="$TAGS gtz-test-b:$$"
  expect_fail "(b) FROM base + USER root (no added files) fails at the parent proof" "parent proof: expected exactly one added layer" "$GATE" "gtz-test-b:$$" "$BASE"
  # (p) clean allowlisted layer passes stages 1-3 and then fails at the first runtime check
  CTX="$WORK/ctxp"; mkdir -p "$CTX/files/usr/share/zoneinfo" "$CTX/files/etc/apk" "$CTX/files/lib/apk/db"
  echo x > "$CTX/files/usr/share/zoneinfo/UTC"; echo tzdata > "$CTX/files/etc/apk/world"
  for f in installed scripts.tar triggers; do echo x > "$CTX/files/lib/apk/db/$f"; done
  chmod -R go-w "$CTX/files"; find "$CTX/files" -type d -exec chmod 755 {} +; find "$CTX/files" -type f -exec chmod 644 {} +
  printf 'FROM %s\nLABEL org.opencontainers.image.base.name=%s\nCOPY --chown=0:0 files/ /\n' "$BASE" "$BASE" > "$CTX/Dockerfile"
  docker buildx build --platform "$PLATFORM" --provenance=false --sbom=false --load -q -t "gtz-test-p:$$" "$CTX" >/dev/null 2>&1; TAGS="$TAGS gtz-test-p:$$"
  out="$("$GATE" "gtz-test-p:$$" "$BASE" 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"ok: parent proof"* && "$out" == *"ok: layer content check"* && "$out" == *"ok: config checks"* && "$out" == *"FAIL: zoneinfo: Asia/Karachi missing"* ]]; then
    ok "(p) clean layer passes stages 1-3, then fails at 'zoneinfo: Asia/Karachi missing'"
  else bad "(p) clean layer passes stages 1-3, then fails at the first runtime check" "rc=$rc $out"; fi
fi

echo
echo "RESULT: $pass passed, $fail failed, $skipped skipped"
[[ $fail -eq 0 ]]
