# Sourced by the outside release watcher before its stdin-delivered CT scripts.
image_retention_lock() {
  image_retention_root=$1/execution-images
  local uid gid
  uid=$(stat -c %u "$1") && gid=$(stat -c %g "$1") || return 2
  if [[ ! -e $image_retention_root && ! -L $image_retention_root ]]; then
    install -d -m 700 -o "$uid" -g "$gid" "$image_retention_root" || return 2
  fi
  python3 - "$image_retention_root" "$uid" <<'PY' || return 2
import os, stat, sys
root, uid = sys.argv[1], int(sys.argv[2])
s = os.lstat(root)
assert stat.S_ISDIR(s.st_mode) and stat.S_IMODE(s.st_mode) == 0o700 and s.st_uid == uid
try:
    fd = os.open(root + '/lock', os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    if os.geteuid() == 0:
        os.fchown(fd, uid, -1)
except FileExistsError:
    fd = os.open(root + '/lock', os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
s = os.fstat(fd)
assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode) == 0o600 and s.st_uid == uid and s.st_nlink == 1
os.fsync(fd)
PY
  exec 9<"$image_retention_root/lock" || return 2
  flock -x 9 || return 2
  python3 - "$image_retention_root" "$uid" <<'PY' || return 2
import os, stat, sys
root, uid = sys.argv[1], int(sys.argv[2])
s, fd = os.lstat(root + '/lock'), os.fstat(9)
r = os.lstat(root)
assert stat.S_ISDIR(r.st_mode) and stat.S_IMODE(r.st_mode) == 0o700 and r.st_uid == uid
assert s.st_dev == fd.st_dev and s.st_ino == fd.st_ino
assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode) == 0o600 and s.st_uid == uid and s.st_nlink == 1
PY
  image_retention_recover || return 2
}

image_retention_recover() {
  python3 - "$image_retention_root" <<'PY'
import hashlib, json, os, re, stat, sys, uuid
try:
    root = sys.argv[1]
    uid = os.lstat(root).st_uid
    names = os.listdir(root)
    for name in names:
        assert name == 'lock' or name.startswith(('.stage-', '.lease-')) or re.fullmatch('[0-9a-f]{64}', name) or (name.endswith('.json') and uuid.UUID(name[:-5]))
    def safe(name, mode, links=1):
        s = os.lstat(root + '/' + name)
        assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode) == mode and s.st_uid == uid and s.st_nlink == links
        return s
    def reference(name, links=1):
        s = safe(name, 0o600, links)
        assert 0 < s.st_size <= 4096
        with open(root + '/' + name) as stream:
            ref = json.load(stream)
        assert uuid.UUID(ref['id']) == uuid.UUID(name[:-5]) and re.fullmatch('[0-9a-f]{64}', ref['digest'])
        assert isinstance(ref['owner'], str) and 0 < len(ref['owner'].encode()) <= 512
        assert ('processID' in ref) == ('birth' in ref)
        if 'processID' in ref:
            assert type(ref['processID']) is int and ref['processID'] > 0 and isinstance(ref['birth'], str) and 0 < len(ref['birth'].encode()) <= 128
        return ref
    for name in names:
        if name.startswith('.stage-'):
            assert name == '.stage-' + str(uuid.UUID(name[7:])).upper()
            s = os.lstat(root + '/' + name)
            mode = stat.S_IMODE(s.st_mode)
            assert mode in (0o500, 0o600) and s.st_nlink in (1, 2)
            safe(name, mode, s.st_nlink)
            if s.st_nlink == 2:
                peers = [n for n in names if n != name and os.path.lexists(root + '/' + n) and (lambda t: (t.st_dev, t.st_ino) == (s.st_dev, s.st_ino))(os.lstat(root + '/' + n))]
                assert len(peers) == 1
                peer = peers[0]
                if mode == 0o600:
                    assert peer == str(uuid.UUID(peer[:-5])).upper() + '.json'
                    reference(peer, 2)
                else:
                    assert re.fullmatch('[0-9a-f]{64}', peer)
                    with open(root + '/' + peer, 'rb') as stream:
                        assert hashlib.file_digest(stream, 'sha256').hexdigest() == peer
            os.unlink(root + '/' + name)
        elif name.startswith('.lease-'):
            assert name == '.lease-' + str(uuid.UUID(name[7:])).upper()
            assert safe(name, 0o600).st_size == 0
    digests = {reference(name)['digest'] for name in names if name.endswith('.json')}
    for name in names:
        if re.fullmatch('[0-9a-f]{64}', name) and name not in digests:
            safe(name, 0o500)
            with open(root + '/' + name, 'rb') as stream:
                assert hashlib.file_digest(stream, 'sha256').hexdigest() == name
            os.unlink(root + '/' + name)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
except Exception:
    print('image retention recovery unsafe; refusing binary deletion', file=sys.stderr)
    sys.exit(2)
PY
}

image_retention_unlock() {
  flock -u 9 && exec 9<&-
}

# 0: deletion allowed; 1: retained; 2: unknown/unsafe evidence, abort deletion.
image_retention_remove_allowed() {
  python3 - "$image_retention_root" "$1" <<'PY'
import hashlib, json, os, re, stat, sys, uuid
try:
    root, binary = sys.argv[1:]
    uid = os.lstat(root).st_uid
    digests = set()
    for name in os.listdir(root):
        if name == 'lock' or name.startswith('.lease-') or re.fullmatch('[0-9a-f]{64}', name):
            continue
        assert name.endswith('.json')
        expected = uuid.UUID(name[:-5])
        fd = os.open(root + '/' + name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            s = os.fstat(fd)
            assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode) == 0o600 and s.st_uid == uid and s.st_nlink == 1 and 0 < s.st_size <= 4096
            ref = json.loads(os.read(fd, 4097))
        finally:
            os.close(fd)
        assert uuid.UUID(ref['id']) == expected and re.fullmatch('[0-9a-f]{64}', ref['digest'])
        assert isinstance(ref['owner'], str) and 0 < len(ref['owner'].encode()) <= 512
        assert ('processID' in ref) == ('birth' in ref)
        if 'processID' in ref:
            assert type(ref['processID']) is int and ref['processID'] > 0 and isinstance(ref['birth'], str) and 0 < len(ref['birth'].encode()) <= 128
        digests.add(ref['digest'])
    if not digests:
        sys.exit(0)
    fd = os.open(binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        assert stat.S_ISREG(os.fstat(stream.fileno()).st_mode)
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    sys.exit(1 if digest in digests else 0)
except Exception:
    print('image retention evidence unsafe; refusing binary deletion', file=sys.stderr)
    sys.exit(2)
PY
}
