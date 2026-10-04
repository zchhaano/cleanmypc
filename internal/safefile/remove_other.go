//go:build !darwin

package safefile

import (
	"context"
	"errors"
)

func removeCurrentUser(context.Context, RemoveRequest) (RemoveResult, error) {
	return RemoveResult{Status: "rejected", ErrorCode: "unsupported_platform"}, errors.New("requires macOS")
}
