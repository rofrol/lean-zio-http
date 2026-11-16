// Tests of the Zig/Lean boundary (zig/src/serve.zig, glue.c, lean/Conn.lean)
// over real sockets. Each scenario starts a server executable with the loop's
// test settings (--chunk, --fail-every, --trace), drives connections against
// it, and then checks, from the server's trace lines, that every connection
// it accepted was freed exactly once. The loop itself ends the process when an
// operation is submitted while another is in flight, when a completion
// arrives without one outstanding (a duplicate or stale completion, also
// after the free, since traced connections stay allocated), or when a receive
// or send reports more bytes than it was given; a scenario then fails with
// the server's output. Exit status 1 when any scenario fails. A server that
// never answers keeps the test from ending; that is a failure to trace.
package main

import (
	"bufio"
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
)

// zioShutWarning is the one server output allowed besides the trace: on macOS
// setsockopt(TCP_NODELAY) fails with EINVAL on an accepted socket whose peer
// reset it before the accept (setsockopt(2): "[EINVAL] The socket has been
// shut down"; reproduced 2026-11-16), and zio's os/net.zig setsockopt (pinned
// 9bef33d) logs every errno but NOPROTOOPT as unexpected. serve.zig ignores the
// error and the connection's receive then fails and closes it, which the
// accounting still checks. Recorded in issues/dqsipn.md.
const zioShutWarning = "warning(zio): unexpected error: .INVAL (22) - please file a bug report: https://github.com/lalinsky/zio/issues/new"

const bodySize = 70001 // lean/Fixture.lean's fixtureBody

var body = func() []byte {
	b := make([]byte, bodySize)
	for i := range b {
		b[i] = byte('a' + i%26)
	}
	return b
}()

const (
	get     = "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
	getLast = "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
	head    = "HEAD / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
)

// server is a running server executable and the trace it prints on stderr.
type server struct {
	cmd    *exec.Cmd
	lines  chan string // stderr lines; closed when the process's stderr ends
	output []string    // every stderr line read so far, for failure reports
}

// start runs path with args and returns once it has printed "ready".
func start(path string, args ...string) (*server, error) {
	cmd := exec.Command(path, args...)
	cmd.Stdout = io.Discard
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	// Large enough for every trace line of a scenario, so a slow reader never
	// blocks the server's stderr writes (which would stall its loops).
	s := &server{cmd: cmd, lines: make(chan string, 1<<20)}
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			s.lines <- sc.Text()
		}
		close(s.lines)
	}()
	for line := range s.lines {
		s.output = append(s.output, line)
		if line == "ready" {
			return s, nil
		}
	}
	s.stop()
	return nil, fmt.Errorf("exited before ready: %s", strings.Join(s.output, " | "))
}

// stop ends the server with SIGTERM, reads the rest of its output and returns
// how the process ended; stopping twice returns the first result.
func (s *server) stop() (*os.ProcessState, error) {
	if s.cmd.ProcessState == nil {
		s.cmd.Process.Signal(syscall.SIGTERM)
		for line := range s.lines {
			s.output = append(s.output, line)
		}
		s.cmd.Wait()
	}
	return s.cmd.ProcessState, nil
}

// trace checks the server's trace lines: each connection opened once and
// freed once after its open, and no other output except, where the scenario
// allows it, zio's EINVAL warning (zioShutWarning).
type trace struct {
	allowShutWarning bool
	open, freed      map[uint64]bool
	ops, shutWarns   uint64
	injRecv, injSend uint64
}

func newTrace(allowShutWarning bool) *trace {
	return &trace{allowShutWarning: allowShutWarning, open: map[uint64]bool{}, freed: map[uint64]bool{}}
}

func (t *trace) take(line string) error {
	f := strings.Fields(line)
	num := func(i int) uint64 { n, _ := strconv.ParseUint(f[i], 10, 64); return n }
	switch {
	case len(f) == 2 && f[0] == "open":
		id := num(1)
		if t.open[id] {
			return fmt.Errorf("connection %d opened twice", id)
		}
		t.open[id] = true
	case len(f) == 5 && f[0] == "free":
		id := num(1)
		if !t.open[id] || t.freed[id] {
			return fmt.Errorf("connection %d freed without an open or twice", id)
		}
		t.freed[id] = true
		t.ops += num(2)
		t.injRecv += num(3)
		t.injSend += num(4)
	case t.allowShutWarning && line == zioShutWarning:
		t.shutWarns++
	default:
		return fmt.Errorf("unexpected server output: %q", line)
	}
	return nil
}

// account reads trace lines until the server has opened `connects`
// connections and freed every one it opened. The client has closed all its
// connections by then, so the server reaches that state unless it lost one.
// It then stops the server and checks the output that came after, and that
// the process ended by the SIGTERM rather than by a panic.
func (s *server) account(t *trace, connects int64) (string, error) {
	for int64(len(t.open)) < connects || len(t.freed) < len(t.open) {
		line, ok := <-s.lines
		if !ok {
			return "", fmt.Errorf("server ended with %d opened, %d freed: %s", len(t.open), len(t.freed), tail(s.output))
		}
		s.output = append(s.output, line)
		if err := t.take(line); err != nil {
			return "", err
		}
	}
	seen := len(s.output)
	st, _ := s.stop()
	for _, line := range s.output[seen:] {
		if err := t.take(line); err != nil {
			return "", fmt.Errorf("after the last free: %w; output: %s", err, tail(s.output))
		}
	}
	if ws, ok := st.Sys().(syscall.WaitStatus); !ok || !ws.Signaled() || ws.Signal() != syscall.SIGTERM {
		return "", fmt.Errorf("server ended with %v, not by SIGTERM: %s", st, tail(s.output))
	}
	if int64(len(t.open)) != connects || len(t.freed) != len(t.open) {
		return "", fmt.Errorf("server opened %d and freed %d connections, client made %d", len(t.open), len(t.freed), connects)
	}
	summary := fmt.Sprintf("%d connections opened and freed once each, %d operations", len(t.open), t.ops)
	if t.injRecv+t.injSend > 0 {
		summary += fmt.Sprintf(", %d receive and %d send failures injected", t.injRecv, t.injSend)
	}
	if t.shutWarns > 0 {
		summary += fmt.Sprintf(", %d zio EINVAL warnings", t.shutWarns)
	}
	return summary, nil
}

func tail(lines []string) string {
	if len(lines) > 20 {
		lines = lines[len(lines)-20:]
	}
	return strings.Join(lines, " | ")
}

// readExact reads one response and checks it: status 200, the fixture body
// for GET, an empty body with the fixture's Content-Length for HEAD.
func readExact(r *bufio.Reader, isHead bool) error {
	req := &http.Request{Method: "GET"}
	if isHead {
		req.Method = "HEAD"
	}
	resp, err := http.ReadResponse(r, req)
	if err != nil {
		return err
	}
	got, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return err
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	if resp.ContentLength != bodySize {
		return fmt.Errorf("Content-Length %d", resp.ContentLength)
	}
	if isHead {
		if len(got) != 0 {
			return fmt.Errorf("HEAD response with %d body bytes", len(got))
		}
	} else if !bytes.Equal(got, body) {
		return fmt.Errorf("body of %d bytes differs from the fixture's", len(got))
	}
	return nil
}

// exchange sends a GET one byte per write, then two pipelined GETs in one
// write, then a HEAD that asks to close; it expects four exact responses and
// the server's close.
func exchange(addr string) error {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		return err
	}
	defer c.Close()
	c.(*net.TCPConn).SetNoDelay(true)
	r := bufio.NewReader(c)
	for i := 0; i < len(get); i++ {
		if _, err := c.Write([]byte{get[i]}); err != nil {
			return err
		}
	}
	if err := readExact(r, false); err != nil {
		return fmt.Errorf("split request: %w", err)
	}
	if _, err := io.WriteString(c, get+get); err != nil {
		return err
	}
	for i := 0; i < 2; i++ {
		if err := readExact(r, false); err != nil {
			return fmt.Errorf("pipelined request %d: %w", i+1, err)
		}
	}
	if _, err := io.WriteString(c, head); err != nil {
		return err
	}
	if err := readExact(r, true); err != nil {
		return fmt.Errorf("HEAD: %w", err)
	}
	if n, err := r.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		return fmt.Errorf("after Connection: close: read %d bytes, %v; want the server's close", n, err)
	}
	return nil
}

// parallel runs f(i) for i in [0, n) on `width` goroutines and returns the
// first error.
func parallel(n, width int, f func(i int) error) error {
	var next atomic.Int64
	var first error
	var mu sync.Mutex
	var wg sync.WaitGroup
	for w := 0; w < width; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				if err := f(i); err != nil {
					mu.Lock()
					if first == nil {
						first = fmt.Errorf("connection %d: %w", i, err)
					}
					mu.Unlock()
				}
			}
		}()
	}
	wg.Wait()
	return first
}

type scenario struct {
	name string
	args []string
	// resets: clients reset connections, possibly before the server accepts
	// them, so on macOS zio's EINVAL warning (zioShutWarning) may appear.
	resets bool
	// injects: the server injects failures, and the trace must show both
	// receive and send failures injected.
	injects bool
	// run drives the server and returns how many connections it made.
	run func(addr string) (int64, string, error)
}

func exchanges(n int) func(addr string) (int64, string, error) {
	return func(addr string) (int64, string, error) {
		return int64(n), "", parallel(n, 16, func(int) error { return exchange(addr) })
	}
}

// failures keeps up to five keep-alive GETs going per connection against a
// server that fails every 29th receive and every 29th send. Every response that arrives whole
// must be exact; an early close or reset is the injected failure. A GET takes
// at least ten operations (a receive and at least nine sends of at most 8192
// bytes, more when the kernel takes less), so some requests usually arrive
// whole and some connections are cut; the scenario fails unless both happen.
// Each of the 64 connections completes at least one receive, and every
// request at least nine sends, so the trace must show both receive and send
// failures injected.
func failures(addr string) (int64, string, error) {
	const n = 64
	var whole, cut atomic.Int64
	err := parallel(n, 16, func(int) error {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			return err
		}
		defer c.Close()
		r := bufio.NewReader(c)
		for k := 0; k < 5; k++ {
			if _, err := io.WriteString(c, get); err != nil {
				cut.Add(1)
				return nil
			}
			err := readExact(r, false)
			if err == nil {
				whole.Add(1)
				continue
			}
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, syscall.ECONNRESET) {
				cut.Add(1)
				return nil
			}
			return err
		}
		return nil
	})
	if err == nil && (whole.Load() == 0 || cut.Load() == 0) {
		err = fmt.Errorf("%d whole responses and %d cut connections; the scenario needs both", whole.Load(), cut.Load())
	}
	return n, fmt.Sprintf("%d whole responses, %d connections cut", whole.Load(), cut.Load()), err
}

// churn opens connections that end in four ways: a complete exchange closed by
// the server, a close before any byte, half a request then a reset, and a
// request whose large response the client resets while the server sends it.
func churn(addr string) (int64, string, error) {
	const n = 2000
	var connects atomic.Int64
	err := parallel(n, 32, func(i int) error {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			return err
		}
		connects.Add(1)
		tc := c.(*net.TCPConn)
		defer tc.Close()
		switch i % 4 {
		case 0:
			if _, err := io.WriteString(c, getLast); err != nil {
				return err
			}
			return readExact(bufio.NewReader(c), false)
		case 1:
			return nil
		case 2:
			io.WriteString(c, get[:len(get)/2])
			tc.SetLinger(0)
			return nil
		default:
			io.WriteString(c, get)
			c.Read(make([]byte, 1))
			tc.SetLinger(0)
			return nil
		}
	})
	return connects.Load(), "", err
}

func main() {
	fixture := flag.String("fixture", "lean/.lake/build/bin/lsrv-fixture", "fixture server executable")
	addr := flag.String("addr", "127.0.0.1:8083", "address the server listens on")
	flag.Parse()
	scenarios := []scenario{
		{"large responses, operations of at most 7 bytes", []string{"2", "--chunk", "7", "--trace"}, false, false, exchanges(8)},
		{"large responses, full-size operations", []string{"2", "--trace"}, false, false, exchanges(16)},
		{"every 29th receive and every 29th send fail", []string{"2", "--fail-every", "29", "--trace"}, false, true, failures},
		{"connection churn with resets", []string{"4", "--trace"}, true, false, churn},
	}
	failed := 0
	for _, sc := range scenarios {
		if err := runScenario(*fixture, *addr, sc); err != nil {
			fmt.Printf("FAIL %s: %v\n", sc.name, err)
			failed++
		}
	}
	fmt.Printf("%d of %d boundary scenarios failed\n", failed, len(scenarios))
	if failed > 0 {
		os.Exit(1)
	}
}

func runScenario(path, addr string, sc scenario) error {
	s, err := start(path, sc.args...)
	if err != nil {
		return err
	}
	defer s.stop()
	connects, note, err := sc.run(addr)
	if err != nil {
		s.stop()
		return fmt.Errorf("%w; server output: %s", err, tail(s.output))
	}
	t := newTrace(sc.resets && runtime.GOOS == "darwin")
	summary, err := s.account(t, connects)
	if err != nil {
		return err
	}
	if sc.injects && (t.injRecv == 0 || t.injSend == 0) {
		return fmt.Errorf("%d receive and %d send failures injected; the scenario needs both", t.injRecv, t.injSend)
	}
	if note != "" {
		summary += "; " + note
	}
	fmt.Printf("ok %s: %s\n", sc.name, summary)
	return nil
}
