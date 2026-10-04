#!/usr/bin/python3
"""Fixed-path PAM transaction. This CLI never accepts alternate system paths.

Library paths and fault hooks exist for isolated unit tests. Release Shell entry
is closed pending VM acceptance; invoking this fixed-path backend requires root.
"""
import fcntl
import os
from pathlib import Path
import stat
import sys
import uuid

RULE = b'auth       sufficient     pam_tid.so\n'

class PamTransaction:
    def __init__(self, pam_dir=Path('/etc/pam.d'), backup_dir=Path('/var/db/atlas/pam'), uid=0, gid=0, hook=None):
        self.pam_dir, self.backup_dir = Path(pam_dir), Path(backup_dir)
        self.uid, self.gid, self.hook = uid, gid, hook
    def _event(self, point, fd):
        if self.hook: self.hook(point, fd)
    def _directory(self, path, private=False):
        raw = str(path)
        for alias in ('/etc', '/var', '/tmp'):
            if raw == alias or raw.startswith(alias + '/'): raw = '/private' + raw; break
        parts = Path(raw).parts
        if not Path(raw).is_absolute() or '..' in parts: raise ValueError('PAM_UNSAFE_DIRECTORY')
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            for part in parts[1:]:
                try: child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                except FileNotFoundError:
                    if not private: raise
                    os.mkdir(part, 0o700, dir_fd=fd)
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                os.close(fd); fd = child
            info = os.fstat(fd)
            if info.st_uid != self.uid or info.st_mode & 0o022: raise ValueError('PAM_UNTRUSTED_DIRECTORY')
            if private and info.st_mode & 0o777 != 0o700: raise ValueError('PAM_UNTRUSTED_BACKUP_DIRECTORY')
            return fd
        except BaseException: os.close(fd); raise
    def _read(self, parent, name, local=False):
        try: fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
        except FileNotFoundError:
            if local: return None, None
            raise
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != self.uid or info.st_gid != self.gid: raise ValueError('PAM_UNTRUSTED_FILE')
            if local and info.st_mode & 0o777 != 0o444: raise ValueError('PAM_UNTRUSTED_MODE')
            if info.st_mode & 0o022: raise ValueError('PAM_WRITABLE_CONFIG')
            data = b''
            while len(data) <= 65536:
                chunk = os.read(fd, 65537 - len(data))
                if not chunk: break
                data += chunk
            if len(data) > 65536: raise ValueError('PAM_CONFIG_TOO_LARGE')
            return data, (info.st_dev, info.st_ino)
        finally: os.close(fd)
    def _stage(self, parent, data, mode, hook=True):
        name = '.atlas-' + uuid.uuid4().hex
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        try:
            if hook: self._event('before_write', fd)
            view = memoryview(data)
            while view:
                count = os.write(fd, view)
                if count <= 0: raise OSError('PAM_SHORT_WRITE')
                view = view[count:]
            os.fchown(fd, self.uid, self.gid); os.fchmod(fd, mode); os.fsync(fd)
            if hook: self._event('before_replace', fd)
            info = os.fstat(fd)
            return name, (info.st_dev, info.st_ino)
        except BaseException:
            os.unlink(name, dir_fd=parent); raise
        finally: os.close(fd)
    def apply(self, operation):
        if operation not in ('enable', 'disable'): raise ValueError('PAM_INVALID_OPERATION')
        parent = self._directory(self.pam_dir)
        try: backup = self._directory(self.backup_dir, private=True)
        except BaseException: os.close(parent); raise
        lock = os.open('transaction.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=backup)
        try:
            lock_info = os.fstat(lock)
            if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != self.uid or lock_info.st_nlink != 1: raise ValueError('PAM_UNTRUSTED_LOCK')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            main, _ = self._read(parent, 'sudo')
            if b'\0' in main or not any(line.split() == [b'auth', b'include', b'sudo_local'] for line in main.splitlines()): raise ValueError('PAM_UNKNOWN_INCLUDE')
            original, old_identity = self._read(parent, 'sudo_local', local=True)
            before = original or b''
            lines = before.splitlines(keepends=True); retained = []
            found = False
            for line in lines:
                tokens = line.split()
                if tokens == [b'auth', b'sufficient', b'pam_tid.so']: found = True; continue
                if b'pam_tid.so' in line and not line.lstrip().startswith(b'#'): raise ValueError('PAM_UNKNOWN_TOUCHID_RULE')
                retained.append(line)
            if operation == 'enable' and found: return 'unchanged'
            if operation == 'disable' and not found: return 'unchanged'
            updated = (RULE if operation == 'enable' else b'') + b''.join(retained)
            if original is not None:
                stage, _ = self._stage(backup, original, 0o600, hook=False)
                os.rename(stage, uuid.uuid4().hex + '.backup', src_dir_fd=backup, dst_dir_fd=backup); os.fsync(backup)
            # Recheck source identity immediately before the fixed-path replacement.
            _, actual_identity = self._read(parent, 'sudo_local', local=True)
            if actual_identity != old_identity: raise ValueError('PAM_IDENTITY_CHANGED')
            stage, staged_identity = self._stage(parent, updated, 0o444)
            changed = False
            try:
                os.replace(stage, 'sudo_local', src_dir_fd=parent, dst_dir_fd=parent); changed = True
                os.fsync(parent); self._event('after_replace', parent)
                verified, _ = self._read(parent, 'sudo_local', local=True)
                verified_main, _ = self._read(parent, 'sudo')
                if verified != updated or verified_main != main: raise ValueError('PAM_POSTCHECK_FAILED')
                if not updated.strip(): os.unlink('sudo_local', dir_fd=parent); os.fsync(parent)
                return 'changed'
            except BaseException:
                if changed:
                    _, actual_identity = self._read(parent, 'sudo_local', local=True)
                    if actual_identity != staged_identity: raise ValueError('PAM_RECONCILIATION_REQUIRED')
                    if original is None: os.unlink('sudo_local', dir_fd=parent)
                    else:
                        rollback, _ = self._stage(parent, original, 0o444, hook=False)
                        os.replace(rollback, 'sudo_local', src_dir_fd=parent, dst_dir_fd=parent)
                    os.fsync(parent)
                raise
            finally:
                try: os.unlink(stage, dir_fd=parent)
                except FileNotFoundError: pass
        finally: os.close(lock); os.close(backup); os.close(parent)

if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != '--vm-acceptance' or os.getuid() != 0: sys.exit('PAM_CAPABILITY_CLOSED')
    marker = Path('/var/db/atlas-disposable-vm')
    try:
        info = marker.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o777 != 0o600: raise ValueError('untrusted VM marker')
    except Exception: sys.exit('PAM_VM_MARKER_REQUIRED')
    # Fixed production paths only. No environment or command line path overrides.
    try: print(PamTransaction().apply(sys.argv[2]))
    except Exception as error: sys.exit('PAM_TRANSACTION_FAILED: ' + str(error))
