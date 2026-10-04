package safefile

import "context"

type FileIdentity struct {
	Device uint64 `json:"device"`
	Inode  uint64 `json:"inode"`
}
type RemoveRequest struct {
	Version      int          `json:"version"`
	Scope        string       `json:"scope"`
	RelativePath string       `json:"relativePath"`
	Expected     FileIdentity `json:"expected"`
}
type RemoveResult struct {
	Status         string `json:"status"`
	RemovedEntries int    `json:"removedEntries"`
	ErrorCode      string `json:"errorCode,omitempty"`
}

func Remove(ctx context.Context, req RemoveRequest) (RemoveResult, error) {
	return removeCurrentUser(ctx, req)
}
