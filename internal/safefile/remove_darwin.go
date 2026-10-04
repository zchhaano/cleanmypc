package safefile

import (
	"context"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"os"
)

func removeCurrentUser(ctx context.Context, req RemoveRequest) (RemoveResult, error) {
	root, uid, err := trustedCacheRoot()
	if err != nil {
		return RemoveResult{Status: "rejected", ErrorCode: "unsupported_user"}, err
	}
	return removeAt(ctx, root, req, uid, nil)
}
func removeAt(ctx context.Context, root string, req RemoveRequest, uid int, afterOpen func()) (result RemoveResult, err error) {
	defer func() {
		if err != nil && result.RemovedEntries == 0 && !errors.Is(err, errPolicy) && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
			result.ErrorCode = "io_failure"
		}
	}()
	result.Status = "rejected"
	result.ErrorCode = "policy_rejected"
	parts, err := requestParts(req)
	if err != nil {
		return result, err
	}
	fd, err := openDirectoryPath(root)
	if err != nil {
		return result, err
	}
	defer func() { unix.Close(fd) }()
	var rootInfo unix.Stat_t
	if err = unix.Fstat(fd, &rootInfo); err != nil {
		return result, err
	}
	if int(rootInfo.Uid) != uid {
		return result, errPolicy
	}
	for _, part := range parts[:len(parts)-1] {
		next, e := unix.Openat(fd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if e != nil {
			return result, e
		}
		unix.Close(fd)
		fd = next
		var s unix.Stat_t
		if e = unix.Fstat(fd, &s); e != nil {
			return result, e
		}
		if e = checkObject(&s, uid, rootInfo.Dev); e != nil {
			return result, e
		}
	}
	name := parts[len(parts)-1]
	var expected unix.Stat_t
	if err = unix.Fstatat(fd, name, &expected, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return result, err
	}
	if uint64(expected.Dev) != req.Expected.Device || expected.Ino != req.Expected.Inode {
		return result, errPolicy
	}
	if err = checkObject(&expected, uid, rootInfo.Dev); err != nil {
		return result, err
	}
	if afterOpen != nil {
		afterOpen()
	}
	visited := 0
	if err = walk(ctx, fd, name, expected, uid, rootInfo.Dev, false, 0, &visited, &result.RemovedEntries); err != nil {
		return result, err
	}
	visited = 0
	err = walk(ctx, fd, name, expected, uid, rootInfo.Dev, true, 0, &visited, &result.RemovedEntries)
	if err != nil {
		if result.RemovedEntries > 0 {
			result.Status = "partial"
			result.ErrorCode = "partial_deletion"
		}
		return result, err
	}
	result.Status = "completed"
	result.ErrorCode = ""
	return result, nil
}
func walk(ctx context.Context, parent int, name string, expected unix.Stat_t, uid int, device int32, deleting bool, depth int, visited, count *int) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	*visited++
	if *visited > 100000 || depth > 64 {
		return errPolicy
	}
	var current unix.Stat_t
	if err := unix.Fstatat(parent, name, &current, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if current.Dev != expected.Dev || current.Ino != expected.Ino {
		return errPolicy
	}
	if err := checkObject(&current, uid, device); err != nil {
		return err
	}
	isDir := current.Mode&unix.S_IFMT == unix.S_IFDIR
	if isDir {
		fd, err := unix.Openat(parent, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err != nil {
			return err
		}
		defer unix.Close(fd)
		var opened unix.Stat_t
		if err = unix.Fstat(fd, &opened); err != nil {
			return err
		}
		if opened.Dev != expected.Dev || opened.Ino != expected.Ino {
			return errPolicy
		}
		duplicate, err := unix.Dup(fd)
		if err != nil {
			return err
		}
		directory := os.NewFile(uintptr(duplicate), "selected-cache-directory")
		defer directory.Close()
		for {
			names, e := directory.Readdirnames(128)
			if e != nil && e != io.EOF {
				return e
			}
			for _, child := range names {
				var info unix.Stat_t
				if err = unix.Fstatat(fd, child, &info, unix.AT_SYMLINK_NOFOLLOW); err != nil {
					return err
				}
				if err = walk(ctx, fd, child, info, uid, device, deleting, depth+1, visited, count); err != nil {
					return err
				}
			}
			if e == io.EOF {
				break
			}
		}
	}
	if deleting {
		if err := ctx.Err(); err != nil {
			return err
		}
		var final unix.Stat_t
		if err := unix.Fstatat(parent, name, &final, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return err
		}
		if final.Dev != expected.Dev || final.Ino != expected.Ino {
			return errPolicy
		}
		flags := 0
		if isDir {
			flags = unix.AT_REMOVEDIR
		}
		if err := unix.Unlinkat(parent, name, flags); err != nil {
			return fmt.Errorf("unlink: %w", err)
		}
		*count++
	}
	return nil
}
