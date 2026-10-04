package safefile

import (
	"context"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"testing"
)

func identity(t *testing.T, path string) FileIdentity {
	t.Helper()
	var s unix.Stat_t
	if err := unix.Lstat(path, &s); err != nil {
		t.Fatal(err)
	}
	return FileIdentity{uint64(s.Dev), s.Ino}
}
func TestConfinedRemovalAndIdentity(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "中文 space")
	os.Mkdir(target, 0700)
	os.WriteFile(filepath.Join(target, "file"), []byte("cache"), 0600)
	outside := filepath.Join(t.TempDir(), "sentinel")
	os.WriteFile(outside, []byte("keep"), 0600)
	req := RemoveRequest{1, "userCaches", "中文 space", identity(t, target)}
	wrong := req
	wrong.Expected.Inode++
	if _, err := removeAt(context.Background(), root, wrong, os.Getuid(), nil); err == nil {
		t.Fatal("identity substitution")
	}
	result, err := removeAt(context.Background(), root, req, os.Getuid(), nil)
	if err != nil || result.Status != "completed" || result.RemovedEntries != 2 {
		t.Fatalf("%+v %v", result, err)
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal(err)
	}
}
func TestRejectRootTraversalSymlinksAndSpecial(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "sentinel"), []byte("keep"), 0600)
	os.Symlink(outside, filepath.Join(root, "link"))
	os.WriteFile(filepath.Join(root, "item"), []byte("cache"), 0600)
	for _, path := range []string{"", ".", "..", "../sentinel", "/", "link/sentinel"} {
		req := RemoveRequest{1, "userCaches", path, identity(t, filepath.Join(root, "item"))}
		if _, err := removeAt(context.Background(), root, req, os.Getuid(), nil); err == nil {
			t.Fatal(path)
		}
	}
	unix.Mkfifo(filepath.Join(root, "fifo"), 0600)
	req := RemoveRequest{1, "userCaches", "fifo", identity(t, filepath.Join(root, "fifo"))}
	if _, err := removeAt(context.Background(), root, req, os.Getuid(), nil); err == nil {
		t.Fatal("fifo")
	}
}
func TestAncestorSwapPreservesOutside(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "parent")
	os.Mkdir(parent, 0700)
	os.WriteFile(filepath.Join(parent, "file"), []byte("cache"), 0600)
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "file"), []byte("keep"), 0600)
	req := RemoveRequest{1, "userCaches", "parent/file", identity(t, filepath.Join(parent, "file"))}
	result, err := removeAt(context.Background(), root, req, os.Getuid(), func() { os.Rename(parent, parent+"-old"); os.Symlink(outside, parent) })
	if err != nil || result.Status != "completed" {
		t.Fatalf("%+v %v", result, err)
	}
	b, _ := os.ReadFile(filepath.Join(outside, "file"))
	if string(b) != "keep" {
		t.Fatal("escaped descriptor")
	}
}

type cancellationAfterCalls struct {
	context.Context
	calls int
}

func (c *cancellationAfterCalls) Err() error {
	c.calls++
	if c.calls > 6 {
		return context.Canceled
	}
	return nil
}
func TestPartialDeletionIsReported(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "selected")
	os.Mkdir(dir, 0700)
	os.WriteFile(filepath.Join(dir, "a"), []byte("a"), 0600)
	os.WriteFile(filepath.Join(dir, "b"), []byte("b"), 0600)
	req := RemoveRequest{Version: 1, Scope: "userCaches", RelativePath: "selected", Expected: identity(t, dir)}
	ctx := &cancellationAfterCalls{Context: context.Background()}
	result, err := removeAt(ctx, root, req, os.Getuid(), nil)
	if err == nil || result.Status != "partial" || result.RemovedEntries != 1 {
		t.Fatalf("%+v %v calls=%d", result, err, ctx.calls)
	}
}
func TestRejectMountAndUnselectedRoot(t *testing.T) {
	var s unix.Stat_t
	s.Uid = uint32(os.Getuid())
	s.Dev = 2
	s.Mode = unix.S_IFDIR
	if checkObject(&s, os.Getuid(), 1) == nil {
		t.Fatal("cross-device")
	}
	req := RemoveRequest{Version: 1, Scope: "userCaches", RelativePath: ".", Expected: FileIdentity{1, 1}}
	if _, err := requestParts(req); err == nil {
		t.Fatal("scope root")
	}
}
