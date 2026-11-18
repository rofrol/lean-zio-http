package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// prSetTHPDisable is PR_SET_THP_DISABLE (<linux/prctl.h>).
const prSetTHPDisable = 41

// disableTHP turns transparent huge pages off for this process and, since
// the setting is inherited across fork and kept across execve (prctl(2)),
// for every fixture server it starts. Lean's mimalloc arena is eligible for
// them: in the Linux check container (transparent_hugepage/enabled
// "madvise", 2026-11-18, item kaslrv) its AnonHugePages equalled its Rss,
// so the resident set grew in 2 MiB steps, 41 KiB per connection over the
// 50 a memory scenario adds (memoryFull read 58 and 99 KiB with the two
// parsers, both under its bound). With them off it grows by the pages the
// connections touch (85 to 88 KiB, the arena 68 to 71 KiB, as macOS's vmmap
// shows). The scenarios measure what a connection holds under base pages,
// not the resident set of a server running with huge pages.
func disableTHP() error {
	if _, _, e := syscall.RawSyscall6(syscall.SYS_PRCTL, prSetTHPDisable, 1, 0, 0, 0, 0); e != 0 {
		return fmt.Errorf("prctl(PR_SET_THP_DISABLE): %w", e)
	}
	return nil
}

// thpOff checks that process pid runs with transparent huge pages off
// (THP_enabled in /proc/PID/status, Linux 5.0 on), so a measurement of it is
// not one taken in 2 MiB steps.
func thpOff(pid int) error {
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, "THP_enabled:"); ok {
			if strings.TrimSpace(v) != "0" {
				return fmt.Errorf("process %d runs with transparent huge pages on (THP_enabled %s)", pid, strings.TrimSpace(v))
			}
			return nil
		}
	}
	return fmt.Errorf("no THP_enabled line in /proc/%d/status", pid)
}
