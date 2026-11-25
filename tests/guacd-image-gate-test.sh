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
expect_fail "(e) symlink 's -> .' plus 'Evil -> s/s/s/../../../etc/shadow' resolves outside" "usr/share/zoneinfo/Evil is a symlink to s/s/s/../../../etc/shadow, outside usr/share/zoneinfo/" \
  "$GATE" --check-layer "$(layer sym-dot-escape)" "$PARENTS"
expect_fail "(e) a member named with // (the escape hidden from the link map) is refused" "member name 'usr/share/zoneinfo//s' is not canonical" \
  "$GATE" --check-layer "$(layer dslash-escape)" "$PARENTS"
expect_fail "(e) a member named with a /./ component is refused" "member name 'usr/share/zoneinfo/./s' is not canonical" \
  "$GATE" --check-layer "$(layer dotseg-escape)" "$PARENTS"
expect_fail "(e) a hard link reached through a symlinked directory" "usr/share/zoneinfo/Hard is a hard link to usr/share/zoneinfo/s/s/UTC through a symlinked directory" \
  "$GATE" --check-layer "$(layer sym-dot-hard)" "$PARENTS"
expect_fail "(e) a hard link with .. components" "usr/share/zoneinfo/Asia/Hard is a hard link to usr/share/zoneinfo/Asia/../../../../etc/shadow, outside" \
  "$GATE" --check-layer "$(layer hard-via-evil)" "$PARENTS"
expect_fail "(e) a hard link to a symlink" "usr/share/zoneinfo/Asia/Hard is a hard link to the symlink usr/share/zoneinfo/Asia/Link; not allowed" \
  "$GATE" --check-layer "$(layer hard-to-symlink)" "$PARENTS"
expect_fail "(e) an entry under a symlinked directory" "usr/share/zoneinfo/D/x is under a symlinked directory" \
  "$GATE" --check-layer "$(layer under-symlink-dir)" "$PARENTS"
expect_fail "(e) a symlink loop" "symlink loop (more than 40 hops)" \
  "$GATE" --check-layer "$(layer sym-loop)" "$PARENTS"
expect_fail "(e2) a group/world-writable zoneinfo directory" "usr/share/zoneinfo/W is group/world-writable" \
  "$GATE" --check-layer "$(layer world-writable-dir)" "$PARENTS"
expect_fail "(e2) a group/world-writable zoneinfo file" "usr/share/zoneinfo/Asia/Ww is group/world-writable" \
  "$GATE" --check-layer "$(layer world-writable-file)" "$PARENTS"
expect_fail "(e2) a zoneinfo file not owned by root" "usr/share/zoneinfo/Asia/Owned is not owned by root" \
  "$GATE" --check-layer "$(layer not-root)" "$PARENTS"
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

echo "== gate failure messages with a stub docker (no Docker needed)"
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/docker" <<'STUBEOF'
#!/usr/bin/env bash
# stub: pull succeeds; save writes an archive holding only an arm64 image
case "$1" in
  pull) exit 0 ;;
  save)
    out=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && out="$2"; shift; done
    d="$(mktemp -d)"; mkdir -p "$d/blobs/sha256"
    echo '{"architecture":"arm64","rootfs":{"diff_ids":["sha256:1"]}}' > "$d/blobs/sha256/$(printf 'a%.0s' $(seq 64))"
    echo '[{"Config":"blobs/sha256/'"$(printf 'a%.0s' $(seq 64))"'","Layers":[]}]' > "$d/manifest.json"
    tar -cf "$out" -C "$d" manifest.json blobs ; exit 0 ;;
esac
exit 1
STUBEOF
chmod +x "$STUB/docker"
expect_fail "an unpack failure prints its own reason" "FAIL: unpack: no amd64 image in the saved archive" \
  env PATH="$STUB:$PATH" "$GATE" "stub:image" "$(tr -d '[:space:]' < "$ROOT/BASE")"

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
      artifact-metadata: write" "job publish permissions must be exactly"
mutant missing-permission "$PUB" "      attestations: write
" "" "job publish permissions must be exactly"
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
mutant secret-ref "$PUB" "password: \${{ github.token }}" "password: \${{ secrets.EXAMPLE }}" "references secrets"
mutant top-permissions "$PUB" "permissions:
  contents: read

defaults" "permissions:
  contents: write

defaults" "top-level permissions must be exactly 'contents: read'"
mutant secrets-index "$PUB" "password: \${{ github.token }}" "password: \${{ secrets['EXAMPLE'] }}" "references secrets"
mutant no-pipefail "$PUB" "defaults:
  run:
    shell: bash
" "" "lacks top-level 'defaults: run: shell: bash'"
mutant ci-trigger .github/workflows/ci.yml "on:
  pull_request:" "on:
  workflow_run:
    workflows: [x]
  pull_request:" "ci.yml triggers must be exactly"
mutant ci-job-permission .github/workflows/ci.yml "  test:
    runs-on: ubuntu-24.04" "  test:
    permissions:
      packages: write
    runs-on: ubuntu-24.04" "ci.yml has a job-level permissions block"
mutant third-job "$PUB" "  scan:
    needs: publish" "  extra:
    runs-on: ubuntu-24.04
    steps: []
  scan:
    needs: publish" "jobs must be exactly publish and scan"
mutant scan-permission "$PUB" "      packages: read" "      packages: write" "job scan permissions must be exactly"
mutant scan-blocking "$PUB" "    continue-on-error: true
    permissions:" "    permissions:" "scan job must be 'needs: publish' with continue-on-error: true"
mutant login-before-gate "$PUB" "      - name: Build
        env:" "      - name: Log in to the registry
        uses: docker/login-action@8aa5831fb8d48d8f76594c7ddde61ae58019f550 # v4.8.0
      - name: Build
        env:" "must have exactly one step named 'Log in"
mutant no-config-bind "$PUB" '"$pushed_config" != "$gated_config"' '"$pushed_config" != "$pushed_config"' "does not compare the pushed config digest with the gated one"
mutant no-republish-guard "$PUB" "already published" "published before" "no refusal for an already published"
mutant loose-media-type "$PUB" "application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json) ;;" "*image.manifest*) ;;" "must accept exactly the OCI and Docker v2 single-manifest media types"
mutant attest-summary "$PUB" "show-summary: false" "show-summary: true" "lacks show-summary: false"
mutant unquoted-label Dockerfile 'USER guacd' 'LABEL com.other.x=y
USER guacd' "label com.other.x must be key=\"value\" (quoted)"
mutant second-label Dockerfile 'USER guacd' 'LABEL other.key="v"
USER guacd' "label keys must be exactly"
mutant build-script-digest scripts/build-guacd-image 'set -euo pipefail' "set -euo pipefail
# sha256:$(printf 'b%.0s' $(seq 64))" "scripts/build-guacd-image carries a literal digest"
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
for want in "(ip.txt): 1 match(es) of ipv4-address" "(mail.txt): 1 match(es) of non-noreply-email" \
  "(home.txt): 1 match(es) of absolute-home-path" "(priv.txt): 1 match(es) of private-pattern-1" \
  "(tz.txt): 1 match(es) of time-zone-label" "(rid.txt): 1 match(es) of review-id-shape"; do
  [[ "$out" == *"$want"* ]] && ok "scanner reports: $want" || bad "scanner reports: $want" "$out"
done
[[ "$out" != *"zzprivateword"* && "$out" != *"someone@"* ]] && ok "the scanner never prints a matched value" || bad "the scanner never prints a matched value"
[[ "$out" != *"(ok.txt)"* ]] && ok "a noreply address is allowed" || bad "a noreply address is allowed"
out="$(cd "$H" && git commit -q --allow-empty -m "$(printf 'fix %s %s-%s' "$(printf 'r%s' 7)" C 1)" && "$H/scripts/check-public-hygiene" --repo "$H" 2>&1)"
[[ "$out" == *"commit "*"match(es) of review-id-shape"* ]] && ok "the scanner reads commit messages" || bad "the scanner reads commit messages" "$out"
out="$(printf 'contact someone\100example.com\n' | "$HYG" --stdin 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"stdin: 1 match(es) of non-noreply-email"* ]] && ok "the scanner reads stdin" || bad "the scanner reads stdin" "$out"
# history and metadata cases
mkrepo() { # mkrepo <dir>: a fresh repo with the scanner, noreply identity, one clean commit
  mkdir -p "$1/scripts" && cp "$ROOT/scripts/deny-patterns" "$ROOT/scripts/check-public-hygiene" "$1/scripts/"
  (cd "$1" && git init -q -b main && git config user.name t && git config user.email "1+t@users.noreply.github.com" \
    && echo "clean text" > a.txt && git add -A && git commit -q -m "generic message")
}
H2="$WORK/hist"; mkrepo "$H2"
(cd "$H2" && echo "zzprivateword" > leak.txt && git add -A && git commit -q -m "add" && git rm -q leak.txt && git commit -q -m "remove")
out="$(HYGIENE_EXTRA_PATTERNS_FILE="$PRIV" "$H2/scripts/check-public-hygiene" --repo "$H2" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"hygiene: FAIL: blob "*"(leak.txt): 1 match(es) of private-pattern-1"* ]] && ok "a value added in one commit and removed in the next is still found (blob)" || bad "history blob scan" "rc=$rc $out"
H3="$WORK/histpath"; mkrepo "$H3"
(cd "$H3" && echo ok > zzprivateword.txt && git add -A && git commit -q -m "add" && git rm -q zzprivateword.txt && git commit -q -m "remove")
out="$(HYGIENE_EXTRA_PATTERNS_FILE="$PRIV" "$H3/scripts/check-public-hygiene" --repo "$H3" 2>&1)"; rc=$?
PH="$(printf 'zzprivateword.txt' | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"
[[ $rc -eq 1 && "$out" == *"hygiene: FAIL: path #"*"(sha256 $PH): 1 match(es) of private-pattern-1"* ]] && ok "a file name that existed only in an earlier commit is found (hashed label)" || bad "historical file name" "rc=$rc $out"
[[ "$out" != *"zzprivateword"* ]] && ok "the private word never appears in the scanner output (path match)" || bad "private word printed for a path match"
H4="$WORK/dirty"; mkrepo "$H4"; echo more >> "$H4/a.txt"
out="$("$H4/scripts/check-public-hygiene" --repo "$H4" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"working tree is dirty; commit or stash before the pre-push scan"* ]] && ok "a dirty working tree is refused (exit 2)" || bad "dirty tree" "rc=$rc $out"
H5="$WORK/hidden"; mkrepo "$H5"
(cd "$H5" && echo "zzprivateword" > leak.txt && git add -A && git commit -q -m "add" && echo clean > leak.txt)
out="$(HYGIENE_EXTRA_PATTERNS_FILE="$PRIV" "$H5/scripts/check-public-hygiene" --repo "$H5" 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "a committed value hidden by a working-tree edit cannot pass (dirty refused)" || bad "hidden edit" "rc=$rc"
H6="$WORK/email"; mkrepo "$H6"
(cd "$H6" && GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git commit -q --allow-empty -m "web merge")
expect_pass "GitHub's own committer address (noreply@github.com) is allowed" "hygiene: clean (0 findings)" "$H6/scripts/check-public-hygiene" --repo "$H6"
(cd "$H6" && GIT_COMMITTER_NAME=Other GIT_COMMITTER_EMAIL="$(printf 'someone\100github.com')" git commit -q --allow-empty -m "other")
expect_fail "any other github.com address still fails" "match(es) of non-noreply-email" "$H6/scripts/check-public-hygiene" --repo "$H6"
H7="$WORK/patfile"; mkrepo "$H7"
(cd "$H7" && printf 'x\tzzprivateword\n' >> scripts/deny-patterns && git add -A && git commit -q -m "edit patterns")
out="$(HYGIENE_EXTRA_PATTERNS_FILE="$PRIV" "$H7/scripts/check-public-hygiene" --repo "$H7" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"(scripts/deny-patterns): 1 match(es) of private-pattern-1"* ]] && ok "the pattern file is NOT exempt from the private patterns" || bad "pattern file private" "rc=$rc $out"
(cd "$H7" && git reset -q --hard HEAD~1 && printf 'x\t%s.%s.%s.%s\n' 10 0 0 1 >> scripts/deny-patterns && git add -A && git commit -q -m "edit patterns again")
expect_pass "the pattern file is exempt from the generic patterns" "hygiene: clean (0 findings)" "$H7/scripts/check-public-hygiene" --repo "$H7"
H8="$WORK/bin"; mkrepo "$H8"
(cd "$H8" && printf 'zzprivateword\000\001' > blob.bin && git add -A && git commit -q -m "binary")
out="$(HYGIENE_EXTRA_PATTERNS_FILE="$PRIV" "$H8/scripts/check-public-hygiene" --repo "$H8" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"(blob.bin): 1 match(es) of private-pattern-1"* && "$out" == *"(1 binary blob(s) included)"* ]] && ok "a binary blob is scanned and counted" || bad "binary blob" "rc=$rc $out"
# the real repo: scan a clone of its committed state (a dirty working tree must not matter for the test)
git clone -q --no-local "$ROOT" "$WORK/realclone" 2>/dev/null || git clone -q "$ROOT" "$WORK/realclone"
expect_pass "the real repo (committed state) passes the generic scan" "hygiene: clean (0 findings)" "$WORK/realclone/scripts/check-public-hygiene" --repo "$WORK/realclone"

echo "== workflow files carry the (p) label rule"
# (p) below relies on a base-name LABEL in its Dockerfile; asserted here so a label rename cannot silently move (p)'s failure point.
# (asserted on the generated Dockerfile text in the real-image section below, where it is written)

echo "== real-image cases (need Docker and one base pull)"
if [[ $DOCKER -eq 0 ]]; then
  skipped=4; echo "SKIPPED: (a), (b), (p) and the (p) label assertion (--no-docker)"
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
  P_DOCKERFILE="$(printf 'FROM %s\nLABEL org.opencontainers.image.base.name=%s\nCOPY --chown=0:0 files/ /\n' "$BASE" "$BASE")"
  [[ "$P_DOCKERFILE" == *$'\nLABEL org.opencontainers.image.base.name='"$BASE"$'\n'* ]] \
    && ok "(p) Dockerfile sets the base-name LABEL (asserted on the generated text)" || bad "(p) Dockerfile sets the base-name LABEL"
  printf '%s\n' "$P_DOCKERFILE" > "$CTX/Dockerfile"
  docker buildx build --platform "$PLATFORM" --provenance=false --sbom=false --load -q -t "gtz-test-p:$$" "$CTX" >/dev/null 2>&1; TAGS="$TAGS gtz-test-p:$$"
  out="$("$GATE" "gtz-test-p:$$" "$BASE" 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"ok: parent proof"* && "$out" == *"ok: layer content check"* && "$out" == *"ok: config checks"* && "$out" == *"FAIL: zoneinfo: Asia/Karachi missing"* ]]; then
    ok "(p) clean layer passes stages 1-3, then fails at 'zoneinfo: Asia/Karachi missing'"
  else bad "(p) clean layer passes stages 1-3, then fails at the first runtime check" "rc=$rc $out"; fi
fi

echo
echo "RESULT: $pass passed, $fail failed, $skipped skipped"
[[ $fail -eq 0 ]]
