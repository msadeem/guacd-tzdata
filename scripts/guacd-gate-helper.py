#!/usr/bin/env python3
"""Helper for scripts/guacd-image-gate. Not meant to be run on its own.

Subcommands (each exits non-zero with one "<stage>: ..." line on failure):
  layer   <added-layer.tar> <base-parents.tsv> <allowlist>   stage 2
  config  <config.json> <base-ref> <base-config.json>         stage 3
  unpack  <docker-save.tar> <outdir> [arch]                   helper for stage 1/2
  parent  <image-outdir> <base-outdir>                        stage 1
"""
import hashlib
import json
import os
import posixpath
import shutil
import sys
import tarfile

ZONEINFO = "usr/share/zoneinfo"
ALLOW_HINT = (
    "; if tzdata changed, re-measure (command in the file header) and review the diff"
)


def fail(msg):
    print(msg)
    sys.exit(1)


def norm(name):
    """Normalise a tar member name. Returns None for names that can never be allowed."""
    n = name
    while n.startswith("./"):
        n = n[2:]
    n = n.rstrip("/")
    if n in ("", "."):
        return ""
    if n.startswith("/") or ".." in n.split("/"):
        return None
    return n


def inside(path, root):
    return path == root or path.startswith(root + "/")


def read_allowlist(path):
    zone, book, extra = None, set(), {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if parts[0] == "zoneinfo" and len(parts) == 2:
                zone = parts[1]
            elif parts[0] == "bookkeeping" and len(parts) == 2:
                book.add(parts[1])
            elif parts[0] == "extra" and len(parts) == 3:
                extra[parts[1]] = parts[2]
            else:
                fail("layer content check: unreadable allowlist line: %s" % line)
    if zone != ZONEINFO:
        fail("layer content check: allowlist has no 'zoneinfo %s' line" % ZONEINFO)
    return book, extra


def read_parents(path):
    d = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            p, mode, uid, gid = line.split("\t")
            d[p] = (int(mode, 8), int(uid), int(gid))
    return d


def cmd_layer(layer, tsv, allow):
    book, extra = read_allowlist(allow)
    parents = read_parents(tsv)
    anc = {ZONEINFO}
    for p in list(book) + list(extra):
        anc.add(p)
    ancestors = set()
    for p in anc:
        parts = p.split("/")
        for i in range(1, len(parts)):
            ancestors.add("/".join(parts[:i]))
    try:
        t = tarfile.open(layer, "r:*")
    except Exception as e:  # noqa: BLE001
        fail("layer content check: cannot read the layer tar (%s)" % e.__class__.__name__)
    for m in t:
        raw = m.name
        n = norm(raw)
        if n == "":
            continue
        if n is None:
            fail("layer content check: %s is not in scripts/guacd-layer-allowlist%s" % (raw, ALLOW_HINT))
        if posixpath.basename(n).startswith(".wh."):
            fail("layer content check: %s is a whiteout entry (deleting a base file); not allowed" % n)
        if inside(n, ZONEINFO):
            if m.isdir():
                if m.mode & 0o6000:
                    fail("layer content check: %s is a directory with setuid or setgid bits" % n)
            elif m.isreg():
                if m.mode & 0o7111:
                    fail("layer content check: %s has setuid, setgid or executable bits" % n)
            elif m.issym():
                tgt = m.linkname
                tgt = posixpath.normpath(tgt.lstrip("/")) if tgt.startswith("/") else posixpath.normpath(
                    posixpath.join(posixpath.dirname(n), tgt))
                if not inside(tgt, ZONEINFO):
                    fail("layer content check: %s is a symlink to %s, outside %s/" % (n, m.linkname, ZONEINFO))
            elif m.islnk():
                tgt = norm(m.linkname)
                if tgt is None or not inside(tgt, ZONEINFO):
                    fail("layer content check: %s is a hard link to %s, outside %s/" % (n, m.linkname, ZONEINFO))
            else:
                fail("layer content check: %s has an unsupported entry type" % n)
            continue
        if n in book or n in extra:
            if not m.isreg():
                fail("layer content check: %s must be a regular file" % n)
            if m.mode & 0o7111:
                fail("layer content check: %s has setuid, setgid or executable bits" % n)
            if n in extra:
                h = hashlib.sha256(t.extractfile(m).read()).hexdigest()
                if h != extra[n]:
                    fail("layer content check: %s does not match the sha256 pinned in scripts/guacd-layer-allowlist" % n)
            continue
        if n in ancestors:
            if not m.isdir():
                fail("layer content check: %s must be a directory" % n)
            if n not in parents:
                fail("layer content check: parent directory %s does not exist in the base" % n)
            want = parents[n]
            got = (m.mode & 0o7777, m.uid, m.gid)
            if got != want:
                fail("layer content check: parent directory %s changed mode/uid/gid compared with the base (got %o %d:%d, base %o %d:%d)"
                     % (n, got[0], got[1], got[2], want[0], want[1], want[2]))
            continue
        fail("layer content check: %s is not in scripts/guacd-layer-allowlist%s" % (n, ALLOW_HINT))
    print("ok: layer content check")


def load_config(path):
    j = json.load(open(path))
    if isinstance(j, list):
        j = j[0]
    return j.get("Config") or j.get("config") or {}


def cmd_config(cfgpath, base_ref, basecfgpath):
    cfg, base = load_config(cfgpath), load_config(basecfgpath)
    if cfg.get("User") != "guacd":
        fail("config check: Config.User is %s, expected guacd" % (cfg.get("User") or "empty"))
    if cfg.get("Entrypoint") != base.get("Entrypoint") or not cfg.get("Entrypoint"):
        fail("config check: Config.Entrypoint %s differs from the base's %s"
             % (json.dumps(cfg.get("Entrypoint")), json.dumps(base.get("Entrypoint"))))
    got = (cfg.get("Labels") or {}).get("org.opencontainers.image.base.name")
    if got != base_ref:
        fail("config check: label org.opencontainers.image.base.name is %s, expected %s" % (got, base_ref))
    print("ok: config checks")


def cmd_unpack(save, outdir, arch="amd64"):
    os.makedirs(outdir, exist_ok=True)
    t = tarfile.open(save, "r:*")
    names = {m.name: m for m in t}
    manifest = json.load(t.extractfile(names["manifest.json"]))
    pick = None
    for e in manifest:
        cfg = json.load(t.extractfile(names[e["Config"]]))
        if cfg.get("architecture") == arch:
            pick = (e, cfg)
            break
    if pick is None:
        fail("unpack: no %s image in the saved archive" % arch)
    e, cfg = pick
    json.dump(cfg, open(os.path.join(outdir, "config.json"), "w"))
    ids = cfg["rootfs"]["diff_ids"]
    open(os.path.join(outdir, "diff_ids"), "w").write("\n".join(ids) + "\n")
    if len(e["Layers"]) != len(ids):
        fail("unpack: %d layer blobs but %d diff_ids" % (len(e["Layers"]), len(ids)))
    dirs = {}
    for blob in e["Layers"]:
        lt = tarfile.open(fileobj=t.extractfile(names[blob]), mode="r|*")
        for m in lt:
            n = norm(m.name)
            if not n:
                continue
            if m.isdir():
                dirs[n] = (m.mode & 0o7777, m.uid, m.gid)
    with open(os.path.join(outdir, "dirs.tsv"), "w") as f:
        for p in sorted(dirs):
            f.write("%s\t%o\t%d\t%d\n" % (p, *dirs[p]))
    last = e["Layers"][-1]
    with open(os.path.join(outdir, "last-layer.tar"), "wb") as f:
        shutil.copyfileobj(t.extractfile(names[last]), f)
    print("ok: unpacked %d layers" % len(ids))


def cmd_parent(imgdir, basedir):
    img = open(os.path.join(imgdir, "diff_ids")).read().split()
    base = open(os.path.join(basedir, "diff_ids")).read().split()
    if img[: len(base)] != base:
        fail("parent proof: the image's layers do not start with the base's layers")
    added = len(img) - len(base)
    if added != 1:
        fail("parent proof: expected exactly one added layer, found %d" % added)
    print("ok: parent proof (base layers + exactly one)")


def main():
    a = sys.argv[1:]
    cmds = {"layer": (cmd_layer, 3), "config": (cmd_config, 3), "unpack": (cmd_unpack, None), "parent": (cmd_parent, 2)}
    if not a or a[0] not in cmds:
        print(__doc__)
        sys.exit(2)
    fn, n = cmds[a[0]]
    if n is not None and len(a) - 1 != n:
        print(__doc__)
        sys.exit(2)
    fn(*a[1:])


if __name__ == "__main__":
    main()
