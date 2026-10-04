package safefile

import (
	"errors"
	"golang.org/x/sys/unix"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
)

var errPolicy = errors.New("unsafe_path_or_object")

func requestParts(req RemoveRequest) ([]string, error) {
	if req.Version != 1 || req.Scope != "userCaches" || req.RelativePath == "" || filepath.IsAbs(req.RelativePath) || strings.ContainsRune(req.RelativePath, 0) || len(req.RelativePath) > 4096 || req.Expected.Inode == 0 {
		return nil, errPolicy
	}
	parts := strings.Split(req.RelativePath, "/")
	if len(parts) > 64 {
		return nil, errPolicy
	}
	for _, p := range parts {
		if p == "" || p == "." || p == ".." {
			return nil, errPolicy
		}
	}
	return parts, nil
}
func trustedCacheRoot() (string, int, error) {
	uid := os.Getuid()
	if uid == 0 {
		return "", uid, errPolicy
	}
	account, err := user.LookupId(strconv.Itoa(uid))
	if err != nil {
		return "", uid, err
	}
	return filepath.Join(account.HomeDir, "Library", "Caches"), uid, nil
}
func openDirectoryPath(path string) (int, error) {
	if path == "/var" || strings.HasPrefix(path, "/var/") || path == "/tmp" || strings.HasPrefix(path, "/tmp/") {
		path = "/private" + path
	}
	if !filepath.IsAbs(path) {
		return -1, errPolicy
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	for _, part := range strings.Split(strings.TrimPrefix(path, "/"), "/") {
		if part == "" || part == "." || part == ".." {
			unix.Close(fd)
			return -1, errPolicy
		}
		next, e := unix.Openat(fd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		unix.Close(fd)
		if e != nil {
			return -1, e
		}
		fd = next
	}
	return fd, nil
}
func checkObject(s *unix.Stat_t, uid int, device int32) error {
	if int(s.Uid) != uid || s.Dev != device {
		return errPolicy
	}
	switch s.Mode & unix.S_IFMT {
	case unix.S_IFREG:
		if s.Nlink != 1 {
			return errPolicy
		}
	case unix.S_IFDIR:
	default:
		return errPolicy
	}
	return nil
}
