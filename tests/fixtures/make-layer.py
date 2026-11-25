#!/usr/bin/env python3
"""make-layer.py <out.tar> <case> -- build a hand-made 'added layer' tar for one test case."""
import io
import sys
import tarfile

out, case = sys.argv[1], sys.argv[2]
t = tarfile.open(out, "w", format=tarfile.GNU_FORMAT)


def add(name, kind="file", mode=0o644, data=b"x", link="", uid=0, gid=0, pax=None):
    ti = tarfile.TarInfo(name)
    ti.mode, ti.uid, ti.gid = mode, uid, gid
    if pax:
        ti.pax_headers = pax
    if kind == "dir":
        ti.type = tarfile.DIRTYPE
        t.addfile(ti)
    elif kind == "sym":
        ti.type, ti.linkname = tarfile.SYMTYPE, link
        t.addfile(ti)
    elif kind == "hard":
        ti.type, ti.linkname = tarfile.LNKTYPE, link
        t.addfile(ti)
    elif kind == "fifo":
        ti.type = tarfile.FIFOTYPE
        t.addfile(ti)
    else:
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))


def parents(etc_mode=0o755, etc_uid=0):
    add("etc", "dir", etc_mode, uid=etc_uid)
    add("etc/apk", "dir", 0o755)
    add("lib", "dir", 0o755)
    add("lib/apk", "dir", 0o755)
    add("lib/apk/db", "dir", 0o755)
    add("usr", "dir", 0o755)
    add("usr/share", "dir", 0o755)
    add("usr/share/zoneinfo", "dir", 0o755)


def bookkeeping(installed=b"P:tzdata\n"):
    add("etc/apk/world", data=b"tzdata\n")
    add("lib/apk/db/installed", data=installed)
    add("lib/apk/db/scripts.tar", data=b"s")
    add("lib/apk/db/triggers", data=b"t")


def zones():
    add("usr/share/zoneinfo/UTC", data=b"utc")
    add("usr/share/zoneinfo/Asia", "dir", 0o755)
    add("usr/share/zoneinfo/Asia/Kolkata", data=b"k")
    add("usr/share/zoneinfo/Asia/Tokyo", data=b"tokyo")
    add("usr/share/zoneinfo/Asia/Calcutta", "hard", link="usr/share/zoneinfo/Asia/Kolkata")
    add("usr/share/zoneinfo/Asia/Link", "sym", 0o777, link="Tokyo")
    add("usr/share/zoneinfo/Asia/Zulu", "sym", 0o777, link="../UTC")
    add("usr/share/zoneinfo/Abs", "sym", 0o777, link="/usr/share/zoneinfo/UTC")


parents()
bookkeeping(b"P:tzdata\nF:usr/local/bin/x\n" if case == "forged-db" else b"P:tzdata\n")
zones()
if case == "clean":
    pass
elif case == "outside-file":
    add("usr/local/bin/x", mode=0o755)
elif case == "forged-db":
    add("usr/local/bin/x", mode=0o755)
elif case == "sym-abs":
    add("usr/share/zoneinfo/Evil", "sym", 0o777, link="/etc/passwd")
elif case == "sym-rel":
    add("usr/share/zoneinfo/Asia/Evil", "sym", 0o777, link="../../../../etc/passwd")
elif case == "whiteout":
    add("usr/share/zoneinfo/.wh.UTC")
elif case == "hard-out":
    add("usr/share/zoneinfo/Evil", "hard", link="etc/apk/world")
elif case == "root-entry":
    add("./", "dir", 0o777, uid=1000)
elif case == "xattr":
    t.close()
    t = tarfile.open(out, "w", format=tarfile.PAX_FORMAT)
    parents()
    bookkeeping()
    zones()
    add("usr/share/zoneinfo/Asia/Opaque", pax={"SCHILY.xattr.trusted.overlay.opaque": "y"})
elif case == "book-uid":
    add("etc/apk/world", uid=1000, gid=1000)
elif case == "book-writable":
    add("lib/apk/db/triggers", mode=0o666)
elif case == "sym-dot-escape":
    add("usr/share/zoneinfo/s", "sym", 0o777, link=".")
    add("usr/share/zoneinfo/Evil", "sym", 0o777, link="s/s/s/../../../etc/shadow")
elif case == "dslash-escape":
    add("usr/share/zoneinfo//s", "sym", 0o777, link=".")
    add("usr/share/zoneinfo/Evil", "sym", 0o777, link="s/s/s/../../../etc/shadow")
elif case == "dotseg-escape":
    add("usr/share/zoneinfo/./s", "sym", 0o777, link=".")
    add("usr/share/zoneinfo/Evil", "sym", 0o777, link="s/s/s/../../../etc/shadow")
elif case == "sym-dot-hard":
    add("usr/share/zoneinfo/s", "sym", 0o777, link=".")
    add("usr/share/zoneinfo/Hard", "hard", link="usr/share/zoneinfo/s/s/UTC")
elif case == "hard-via-evil":
    add("usr/share/zoneinfo/Asia/Hard", "hard", link="usr/share/zoneinfo/Asia/../../../../etc/shadow")
elif case == "hard-to-symlink":
    add("usr/share/zoneinfo/Asia/Hard", "hard", link="usr/share/zoneinfo/Asia/Link")
elif case == "under-symlink-dir":
    add("usr/share/zoneinfo/D", "sym", 0o777, link="Asia")
    add("usr/share/zoneinfo/D/x", data=b"x")
elif case == "sym-loop":
    add("usr/share/zoneinfo/La", "sym", 0o777, link="Lb")
    add("usr/share/zoneinfo/Lb", "sym", 0o777, link="La")
elif case == "world-writable-dir":
    add("usr/share/zoneinfo/W", "dir", 0o777)
elif case == "world-writable-file":
    add("usr/share/zoneinfo/Asia/Ww", mode=0o666)
elif case == "not-root":
    add("usr/share/zoneinfo/Asia/Owned", uid=1000, gid=1000)
elif case == "exec":
    add("usr/share/zoneinfo/Asia/Run", mode=0o755)
elif case == "setuid":
    add("usr/share/zoneinfo/Asia/Su", mode=0o4644)
elif case == "parent-mode":
    t.close()
    t = tarfile.open(out, "w", format=tarfile.GNU_FORMAT)
    parents(etc_mode=0o777)
    bookkeeping()
    zones()
elif case == "parent-uid":
    t.close()
    t = tarfile.open(out, "w", format=tarfile.GNU_FORMAT)
    parents(etc_uid=1000)
    bookkeeping()
    zones()
elif case == "parent-unknown":
    add("usr/lib", "dir", 0o755)
    add("usr/lib/etc.conf")
elif case == "traversal":
    add("usr/share/zoneinfo/../../../etc/x")
elif case == "book-symlink":
    t.close()
    t = tarfile.open(out, "w", format=tarfile.GNU_FORMAT)
    parents()
    add("etc/apk/world", "sym", 0o777, link="/etc/passwd")
elif case == "book-exec":
    add("etc/apk/world", mode=0o755)
elif case == "fifo":
    add("usr/share/zoneinfo/Fifo", "fifo")
elif case == "extra-ok":
    add("usr/share/tzextra.conf", data=b"pinned")
elif case == "extra-bad":
    add("usr/share/tzextra.conf", data=b"tampered")
else:
    sys.exit("unknown case " + case)
t.close()
