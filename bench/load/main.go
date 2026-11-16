// Closed-loop HTTP/1.1 keep-alive load generator: C connections send GET
// requests back to back until the measurement endpoint (start + D). Only
// responses with the expected status and body count; any other outcome makes
// the run fail (exit status 1). Throughput is divided by the time actually
// elapsed until the last connection finished its outstanding request. A
// server that stalls keeps the run from ending; that is a failure to trace,
// never a result.
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

func main() {
	url := flag.String("url", "", "URL to request")
	c := flag.Int("c", 64, "connections")
	d := flag.Duration("d", 10*time.Second, "duration until the measurement endpoint")
	want := flag.String("body", "Hello, World!", "expected response body")
	flag.Parse()
	expected := []byte(*want)

	tr := &http.Transport{MaxIdleConnsPerHost: *c, MaxConnsPerHost: *c, DisableCompression: true}
	// Redirects are not followed: a 3xx is a failure, like any status but 200.
	cl := &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	var mu sync.Mutex
	var lat []time.Duration
	var failures []string
	start := time.Now()
	end := start.Add(*d)
	var wg sync.WaitGroup
	for i := 0; i < *c; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var l []time.Duration
			var fail string
			for fail == "" && time.Now().Before(end) {
				t := time.Now()
				r, err := cl.Get(*url)
				if err != nil {
					fail = err.Error()
					break
				}
				body, err := io.ReadAll(r.Body)
				r.Body.Close()
				switch {
				case err != nil:
					fail = "reading body: " + err.Error()
				case r.StatusCode != 200:
					fail = fmt.Sprintf("status %d", r.StatusCode)
				case !bytes.Equal(body, expected):
					fail = fmt.Sprintf("unexpected body %q", body)
				default:
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
	wg.Wait()
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
