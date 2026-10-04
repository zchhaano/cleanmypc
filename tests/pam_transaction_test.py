import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

module_path = Path(__file__).parents[1] / 'lib/manage/pam_transaction.py'
spec = importlib.util.spec_from_file_location('pam_transaction', module_path)
pam = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pam)

class PamTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.pam_dir = self.root / 'pam'; self.pam_dir.mkdir(mode=0o700)
        (self.pam_dir / 'sudo').write_text('auth include sudo_local\nauth required pam_opendirectory.so\n')
        self.backup = self.root / 'backup'
    def tearDown(self): self.tmp.cleanup()
    def transaction(self, hook=None): return pam.PamTransaction(self.pam_dir, self.backup, uid=os.getuid(), gid=os.getgid(), hook=hook)
    def local(self, content):
        path = self.pam_dir / 'sudo_local'
        if path.exists(): path.chmod(0o600)
        path.write_text(content); path.chmod(0o444); return path
    def testEnableDisableIdempotenceAndPreserveThirdParty(self):
        original = 'auth optional pam_krb5.so\n# third-party comment\n'
        path = self.local(original); main = (self.pam_dir / 'sudo').read_bytes()
        tx = self.transaction(); tx.apply('enable'); once = path.read_bytes(); tx.apply('enable')
        self.assertEqual(path.read_bytes(), once); self.assertEqual(path.stat().st_mode & 0o777, 0o444)
        tx.apply('disable'); self.assertEqual(path.read_text(), original)
        self.assertEqual((self.pam_dir / 'sudo').read_bytes(), main)
        for backup in self.backup.glob('*.backup'): self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
    def testMetadataIsSetBeforeReplacementAndRollbackDoesNotElevateAgain(self):
        path = self.local('auth optional pam_krb5.so\n'); before = path.read_bytes()
        def fail(point, fd):
            if point == 'before_replace': self.assertEqual(os.fstat(fd).st_mode & 0o777, 0o444)
            if point == 'after_replace': raise OSError('simulated post-check failure')
        with self.assertRaises(Exception): self.transaction(fail).apply('enable')
        self.assertEqual(path.read_bytes(), before); self.assertEqual(path.stat().st_mode & 0o777, 0o444)
    def testRejectSymlinkHardlinkModeAndUnknownInclude(self):
        sentinel = self.root / 'sentinel'; sentinel.write_text('keep')
        path = self.pam_dir / 'sudo_local'; path.symlink_to(sentinel)
        with self.assertRaises(Exception): self.transaction().apply('enable')
        self.assertEqual(sentinel.read_text(), 'keep'); path.unlink()
        os.link(sentinel, path)
        with self.assertRaises(Exception): self.transaction().apply('enable')
        path.unlink(); path = self.local('auth optional pam_krb5.so\n'); path.chmod(0o644)
        with self.assertRaises(Exception): self.transaction().apply('enable')
        path.chmod(0o444); (self.pam_dir / 'sudo').write_text('unknown include\n')
        with self.assertRaises(Exception): self.transaction().apply('enable')
    def testWriteFailureNeverChangesOriginalAndEmptyDisableRemovesLocal(self):
        path = self.local('auth optional pam_krb5.so\n'); before = path.read_bytes()
        def fail(point, fd):
            if point == 'before_write': raise OSError('ENOSPC')
        with self.assertRaises(Exception): self.transaction(fail).apply('enable')
        self.assertEqual(path.read_bytes(), before)
        path = self.local('auth sufficient pam_tid.so\n')
        self.transaction().apply('disable'); self.assertFalse(path.exists())

if __name__ == '__main__': unittest.main()
