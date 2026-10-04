package main

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/tw93/mole/internal/safefile"
	"io"
	"os"
	"time"
)

func run(input io.Reader, output io.Writer) int {
	data, readError := io.ReadAll(io.LimitReader(input, 16385))
	if readError != nil || len(data) > 16384 {
		json.NewEncoder(output).Encode(safefile.RemoveResult{Status: "rejected", ErrorCode: "invalid_request"})
		return 2
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var req safefile.RemoveRequest
	if decoder.Decode(&req) != nil {
		json.NewEncoder(output).Encode(safefile.RemoveResult{Status: "rejected", ErrorCode: "invalid_request"})
		return 2
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		json.NewEncoder(output).Encode(safefile.RemoveResult{Status: "rejected", ErrorCode: "invalid_request"})
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	result, err := safefile.Remove(ctx, req)
	json.NewEncoder(output).Encode(result)
	return exitCode(result, err)
}

func exitCode(result safefile.RemoveResult, err error) int {
	if result.Status == "completed" && err == nil {
		return 0
	}
	if result.Status == "partial" {
		return 3
	}
	if result.ErrorCode == "io_failure" {
		return 4
	}
	return 2
}
func main() { os.Exit(run(os.Stdin, os.Stdout)) }
