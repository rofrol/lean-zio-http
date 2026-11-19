// The canary of item srx6tz (docs/reports/fairness-probe-maxima.md): spins
// on one locked thread until SIGTERM or SIGINT, keeping every pause between
// two clock reads longer than -min, then prints them as `start_ns
// length_ns` (wall clock). It keeps them in memory while it spins, so that
// writing them causes no pause of its own. Build it with
// `go build -o canary canary.go`.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	min := flag.Duration("min", 200*time.Microsecond, "smallest pause kept")
	flag.Parse()
	var stop atomic.Bool
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-sig; stop.Store(true) }()
	runtime.LockOSThread()
	type pause struct{ start, length int64 }
	pauses := make([]pause, 0, 1<<16)
	last := time.Now()
	for !stop.Load() {
		now := time.Now()
		if g := now.Sub(last); g > *min {
			pauses = append(pauses, pause{last.UnixNano(), g.Nanoseconds()})
		}
		last = now
	}
	for _, p := range pauses {
		fmt.Println(p.start, p.length)
	}
}
