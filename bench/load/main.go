// Closed-loop HTTP/1.1 keep-alive load generator: C connections send GET
// requests back to back until the measurement endpoint (start + D). Only
// responses with the expected status and body count; any other outcome makes
// the run fail (exit status 1). Throughput is divided by the time actually
// elapsed until the last connection finished its outstanding request. A
// server that stalls keeps the run from ending; that is a failure to trace,
// never a result.
//
// The connections are opened before the measurement, which therefore excludes
// connection setup: each connection sends one warm-up request (checked like
// every other) and waits for its response, the event that shows the server
// accepted it, with at most setupWindow connections awaiting that first
// response at a time; the clock starts once every connection has answered.
// The window keeps the burst of new connections within the listen queue of
// the machine the load runs on: macOS holds at most 128 unaccepted connections
// (kern.ipc.somaxconn) and resets the rest (README, "The dusty failure at 256
// connections").
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

// setupWindow: the most connections awaiting their warm-up response at once,
// the listen queue's capacity on macOS (kern.ipc.somaxconn = 128).
const setupWindow = 128

func main() {
	url := flag.String("url", "", "URL to request")
	c := flag.Int("c", 64, "connections")
	d := flag.Duration("d", 10*time.Second, "duration until the measurement endpoint")
	want := flag.String("body", "Hello, World!", "expected response body")
	flag.Parse()
	expected := []byte(*want)

	// get sends one request on cl and returns why it failed, or "".
	get := func(cl *http.Client) string {
		r, err := cl.Get(*url)
		if err != nil {
			return err.Error()
		}
		body, err := io.ReadAll(r.Body)
		r.Body.Close()
		switch {
		case err != nil:
			return "reading body: " + err.Error()
		case r.StatusCode != 200:
			return fmt.Sprintf("status %d", r.StatusCode)
		case !bytes.Equal(body, expected):
			return fmt.Sprintf("unexpected body %q", body)
		}
		return ""
	}

	var mu sync.Mutex
	var lat []time.Duration
	var failures []string
	window := make(chan struct{}, setupWindow)
	var opened, done sync.WaitGroup
	measuring := make(chan struct{})
	var end time.Time // written before measuring is closed
	for i := 0; i < *c; i++ {
		opened.Add(1)
		done.Add(1)
		go func() {
			defer done.Done()
			// Each connection has its own transport, so that the warm-up
			// request opens this connection and no later request takes it
			// over from another one.
			cl := &http.Client{
				Transport: &http.Transport{MaxIdleConnsPerHost: 1, MaxConnsPerHost: 1, DisableCompression: true},
				// Redirects are not followed: a 3xx is a failure, like any status but 200.
				CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
			}
			window <- struct{}{}
			fail := get(cl)
			<-window
			if fail != "" {
				fail = "warm-up: " + fail
			}
			opened.Done()
			<-measuring
			var l []time.Duration
			for fail == "" && time.Now().Before(end) {
				t := time.Now()
				if fail = get(cl); fail == "" {
					l = append(l, time.Since(t))
				}
			}
			mu.Lock()
			lat = append(lat, l...)
			if fail != "" {
				failures = append(failures, fail)
			}
			mu.Unlock()
		}()
	}
	opened.Wait()
	start := time.Now()
	end = start.Add(*d)
	close(measuring)
	done.Wait()
	elapsed := time.Since(start)
	if len(failures) > 0 {
		fmt.Printf("FAILED: %d connections failed, first: %s\n", len(failures), failures[0])
		os.Exit(1)
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	n := len(lat)
	if n == 0 {
		fmt.Println("FAILED: no responses")
		os.Exit(1)
	}
	fmt.Printf("req/s=%.0f p50=%v p99=%v max=%v n=%d elapsed=%v\n",
		float64(n)/elapsed.Seconds(), lat[n/2], lat[n*99/100], lat[n-1], n, elapsed.Round(time.Millisecond))
}
