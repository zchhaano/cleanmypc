package main

import (
	"bytes"
	"github.com/tw93/mole/internal/safefile"
	"io"
	"strings"
	"testing"
)

func TestInvalidRequestsFailClosed(t *testing.T) {
	for _, data := range []string{"{}", "null", "{\"unknown\":1}", "{}{}", strings.Repeat("x", 20000)} {
		var out bytes.Buffer
		if run(strings.NewReader(data), &out) != 2 {
			t.Fatal(data)
		}
		if !strings.Contains(out.String(), "rejected") {
			t.Fatal(out.String())
		}
	}
}

func TestExitCodesDistinguishIOAndPartialFailures(t *testing.T) {
	if exitCode(safefile.RemoveResult{Status: "rejected", ErrorCode: "io_failure"}, io.ErrUnexpectedEOF) != 4 {
		t.Fatal("I/O must have its own exit code")
	}
	if exitCode(safefile.RemoveResult{Status: "partial"}, io.ErrUnexpectedEOF) != 3 {
		t.Fatal("partial failure")
	}
}
