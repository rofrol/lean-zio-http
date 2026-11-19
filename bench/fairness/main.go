// The service latency of a connection that shares one event loop with a
// connection that sends small pipelined requests without pause, meant to
// fill its buffer on every receive (item vhvejg). Against a server started with one loop
// (`lsrv-arena 1`), it opens two connections:
//
//   - the loader (unless -load none) writes one request, the -load case's,
//     back to back without pause, and reads and checks every response (its
//     status line and body). The stream is meant to leave more bytes waiting
//     in the server's socket than its buffer has room for at each receive, so
//     that each step answers as many requests as fit in one send
//     (Conn.gather); the harness does not observe the server's receives;
//   - the probe sends `GET /pipeline` and waits for its `200 ok`, -n times
//     one after the other, timing each round trip.
//
// The probes start once the loader's first response has been read, so the
// loop is serving it. It prints the probe's latency percentiles and the
// loader's responses per second while the probes ran. Any response with
// another status or body, a framing other than one Content-Length, or a
// loader error other than the one closing its socket at the end causes,
// makes it exit 1.
// It measures only: its figures are machine-dependent and draw no
// conclusion.
package main

import (
	"bufio"
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// The requests of Corpus.fullCases (Corpus.lean), with the status line and
// body App.Arena answers each with (App/Arena.lean).
var loads = map[string]struct{ req, status, body string }{
	"404":      {"GET / HTTP/1.1\r\nHost:\r\n\r\n", "HTTP/1.1 404 ", "404 page not found\n"},
	"pipeline": {"GET /pipeline HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n", "HTTP/1.1 200 ", "ok"},
}

// inCap is Server.inCap (Server/Wire.lean): the bytes a connection buffers.
// The loader writes this many bytes of requests at a time; the stream is
// continuous, so how the kernel splits it does not matter.
const inCap = 8192 + 4 + 8192

const probeReq = "GET /pipeline HTTP/1.1\r\nHost: a\r\n\r\n"

// readResponse reads one response framed by a single Content-Length and
// returns an error unless it starts with status and carries body. A read
// error is wrapped, so errors.Is finds net.ErrClosed in it.
func readResponse(r *bufio.Reader, status string, body []byte) error {
	line, err := r.ReadString('\n')
	if err != nil {
		return fmt.Errorf("reading status line: %w", err)
	}
	if !strings.HasPrefix(line, status) {
		return fmt.Errorf("status line %q, want %q", line, status)
	}
	length := -1
	for {
		h, err := r.ReadString('\n')
		if err != nil {
			return fmt.Errorf("reading header: %w", err)
		}
		if h == "\r\n" {
			break
		}
		k, v, _ := strings.Cut(h, ":")
		switch {
		case strings.EqualFold(k, "Transfer-Encoding"):
			return fmt.Errorf("Transfer-Encoding %q: only Content-Length framing is read", v)
		case strings.EqualFold(k, "Content-Length"):
			if length >= 0 {
				return errors.New("more than one Content-Length")
			}
			// Only the expected body's length is read, so that a longer one
			// cannot leave the read waiting for bytes that never come.
			d := strings.TrimSpace(v)
			n, err := strconv.Atoi(d)
			if err != nil || strings.Trim(d, "0123456789") != "" || n != len(body) {
				return fmt.Errorf("Content-Length %q, want %d", v, len(body))
			}
			length = n
		}
	}
	if length < 0 {
		return errors.New("no Content-Length")
	}
	b := make([]byte, length)
	if _, err := io.ReadFull(r, b); err != nil {
		return fmt.Errorf("reading body: %w", err)
	}
	if !bytes.Equal(b, body) {
		return fmt.Errorf("body %q, want %q", b, body)
	}
	return nil
}

func fail(format string, a ...any) {
	fmt.Printf("FAILED: "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	addr := flag.String("addr", "", "host:port of a server with one loop")
	load := flag.String("load", "none", "the loader's requests: none, 404 or pipeline")
	n := flag.Int("n", 20000, "probe requests, at least 1")
	flag.Parse()
	if *n < 1 {
		fail("-n %d: want at least 1", *n)
	}

	var served atomic.Int64
	firstServed := make(chan struct{})
	// The loader's goroutines; each ends on its first error. An error that
	// is not the one closing the socket at the end causes (net.ErrClosed)
	// ends the run at once, so none is lost.
	var loaders sync.WaitGroup
	loaderErr := func(what string, err error) {
		if !errors.Is(err, net.ErrClosed) {
			fail("loader %s: %v", what, err)
		}
	}
	var loader net.Conn
	if *load != "none" {
		l, ok := loads[*load]
		if !ok {
			fail("-load %q: want none, 404 or pipeline", *load)
		}
		c, err := net.Dial("tcp", *addr)
		if err != nil {
			fail("loader: %v", err)
		}
		loader = c
		chunk := bytes.Repeat([]byte(l.req), inCap/len(l.req))
		loaders.Add(2)
		go func() {
			defer loaders.Done()
			for {
				if _, err := c.Write(chunk); err != nil {
					loaderErr("write", err)
					return
				}
			}
		}()
		go func() {
			defer loaders.Done()
			r := bufio.NewReaderSize(c, 1<<16)
			for {
				if err := readResponse(r, l.status, []byte(l.body)); err != nil {
					loaderErr("read", err)
					return
				}
				if served.Add(1) == 1 {
					close(firstServed)
				}
			}
		}()
		<-firstServed
	}

	p, err := net.Dial("tcp", *addr)
	if err != nil {
		fail("probe: %v", err)
	}
	r := bufio.NewReader(p)
	lat := make([]time.Duration, 0, *n)
	before := served.Load()
	start := time.Now()
	for i := 0; i < *n; i++ {
		t := time.Now()
		if _, err := p.Write([]byte(probeReq)); err != nil {
			fail("probe write: %v", err)
		}
		if err := readResponse(r, "HTTP/1.1 200 ", []byte("ok")); err != nil {
			fail("probe: %v", err)
		}
		lat = append(lat, time.Since(t))
	}
	elapsed := time.Since(start)
	after := served.Load()
	if loader != nil {
		loader.Close()
		loaders.Wait()
	}
	p.Close()

	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	q := func(f float64) time.Duration { return lat[int(f*float64(len(lat)-1))] }
	fmt.Printf("load=%s probes=%d p50=%v p90=%v p99=%v p99.9=%v max=%v loader_resp/s=%.0f\n",
		*load, len(lat), q(0.5), q(0.9), q(0.99), q(0.999), lat[len(lat)-1],
		float64(after-before)/elapsed.Seconds())
}
