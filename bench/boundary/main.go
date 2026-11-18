// Tests of the Zig/Lean boundary (zig/src/serve.zig, glue.c,
// Server/Conn.lean) over real sockets. Each scenario starts a server
// executable with the loop's test settings (--chunk, --fail-every, --trace,
// --max-conns, --crash-after-recv, --crash-after-send) or short deadline
// budgets (--idle-ms, --head-ms, --body-ms), drives connections
// against it, and then checks, from the server's trace lines, that every
// connection it accepted was freed exactly once and that SIGTERM ended it
// gracefully (exit status 0 after "stopped"). The crash scenarios check what
// a peer sees when the process dies between an effect and its record. The
// loop itself ends the process when an
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
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const bodySize = 60001 // App/Fixture.lean's body

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
	addr   string      // host:port it listens on, from its "listening on" line
	lines  chan string // stderr lines; closed when the process's stderr ends
	output []string    // every stderr line read so far, for failure reports
}

// end reads the rest of the server's output and waits for the process to
// end on its own (after a crash point).
func (s *server) end() *os.ProcessState {
	for line := range s.lines {
		s.output = append(s.output, line)
	}
	s.cmd.Wait()
	return s.cmd.ProcessState
}

// until reads trace lines into t until done(t) holds.
func (s *server) until(t *trace, done func(*trace) bool) error {
	for !done(t) {
		line, ok := <-s.lines
		if !ok {
			return fmt.Errorf("server ended: %s", tail(s.output))
		}
		s.output = append(s.output, line)
		if err := t.take(line); err != nil {
			return err
		}
	}
	return nil
}

// start runs path with args on a port the kernel picks and returns once it
// has printed "ready", with the address its "listening on" line reported.
func start(path string, args ...string) (*server, error) {
	cmd := exec.Command(path, append(args, "--port", "0")...)
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
		if a, ok := strings.CutPrefix(line, "listening on "); ok {
			s.addr = strings.Fields(a)[0]
		}
		if line == "ready" {
			if s.addr == "" {
				s.stop()
				return nil, fmt.Errorf("ready without a listening on line: %s", strings.Join(s.output, " | "))
			}
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
// freed once after its open, and no other output. No scenario allows a
// warning: the server sets no option on an accepted socket (serve.zig,
// openListener), so even the churn scenario's connections reset before the
// accept give zio nothing to warn about.
type trace struct {
	open, freed      map[uint64]bool
	ops              uint64
	injRecv, injSend uint64
	stopped          int
	// Sends in flight when a loop's stop arrived (its "stop R S" lines).
	sendsAtStop uint64
}

func newTrace() *trace {
	return &trace{open: map[uint64]bool{}, freed: map[uint64]bool{}}
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
	case len(f) == 3 && f[0] == "stop":
		t.sendsAtStop += num(2)
	case line == "stopped":
		t.stopped++
	default:
		return fmt.Errorf("unexpected server output: %q", line)
	}
	return nil
}

// account reads trace lines until the server has opened `connects`
// connections and freed every one it opened. The client has closed all its
// connections by then, so the server reaches that state unless it lost one.
// It then stops the server with SIGTERM and checks the output that came
// after, and that the process shut down gracefully: "stopped" once, exit
// status 0.
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
	if !st.Success() || t.stopped != 1 {
		return "", fmt.Errorf("server ended with %v after %d \"stopped\" lines, not by a graceful shutdown: %s", st, t.stopped, tail(s.output))
	}
	if int64(len(t.open)) != connects || len(t.freed) != len(t.open) {
		return "", fmt.Errorf("server opened %d and freed %d connections, client made %d", len(t.open), len(t.freed), connects)
	}
	summary := fmt.Sprintf("%d connections opened and freed once each, %d operations", len(t.open), t.ops)
	if t.injRecv+t.injSend > 0 {
		summary += fmt.Sprintf(", %d receive and %d send failures injected", t.injRecv, t.injSend)
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

const continueBytes = "HTTP/1.1 100 Continue\r\n\r\n"

func dial(addr string) (*net.TCPConn, error) {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	tc := c.(*net.TCPConn)
	tc.SetNoDelay(true)
	return tc, nil
}

// expectEOF reads from r and requires the server's close with no byte before it.
func expectEOF(r io.Reader, what string) error {
	n, err := r.Read(make([]byte, 1))
	if n != 0 || (err != io.EOF && !errors.Is(err, syscall.ECONNRESET)) {
		return fmt.Errorf("%s: read %d bytes, %v; want the server's close", what, n, err)
	}
	return nil
}

// expectations sends a POST with `Expect: 100-continue`, waits for the
// interim response before sending the body, and checks the echoed body; then
// asks for /too-big, whose body exceeds the bounded output, and expects 500
// with the fixture's own field X-Robots-Tag, and the server's close.
func expectations(addr string) (int64, string, error) {
	c, err := dial(addr)
	if err != nil {
		return 0, "", err
	}
	defer c.Close()
	r := bufio.NewReader(c)
	io.WriteString(c, "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
	interim := make([]byte, len(continueBytes))
	if _, err := io.ReadFull(r, interim); err != nil || string(interim) != continueBytes {
		return 1, "", fmt.Errorf("interim response %q, %v", interim, err)
	}
	io.WriteString(c, "hello")
	resp, err := http.ReadResponse(r, &http.Request{Method: "POST"})
	if err != nil {
		return 1, "", err
	}
	got, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(got) != "hello" {
		return 1, "", fmt.Errorf("echo: status %d body %q", resp.StatusCode, got)
	}
	c2, err := dial(addr)
	if err != nil {
		return 1, "", err
	}
	defer c2.Close()
	r2 := bufio.NewReader(c2)
	io.WriteString(c2, "GET /too-big HTTP/1.1\r\nHost: a\r\n\r\n")
	resp, err = http.ReadResponse(r2, &http.Request{Method: "GET"})
	if err != nil {
		return 2, "", err
	}
	io.ReadAll(resp.Body)
	if resp.StatusCode != 500 {
		return 2, "", fmt.Errorf("/too-big: status %d, want 500", resp.StatusCode)
	}
	if got := resp.Header.Values("X-Robots-Tag"); len(got) != 1 || got[0] != "noindex, nofollow" {
		return 2, "", fmt.Errorf("/too-big: X-Robots-Tag %q, want the fixture's own field", got)
	}
	return 2, "", expectEOF(r2, "after the 500")
}

// shutdown sends SIGTERM to a one-loop server while it holds three
// connections: one in the middle of a 60,001-byte response sent 7 bytes per
// operation, one idle, one with half a request. The response must arrive
// whole, then every connection must see the server's close with nothing
// else, and the process must stop gracefully.
func shutdown(path string) (string, error) {
	s, err := start(path, "1", "--chunk", "7", "--trace")
	if err != nil {
		return "", err
	}
	addr := s.addr
	defer s.stop()
	t := newTrace()
	a, err := dial(addr)
	if err != nil {
		return "", err
	}
	defer a.Close()
	ra := bufio.NewReader(a)
	io.WriteString(a, get)
	if _, err := ra.Peek(1); err != nil {
		return "", fmt.Errorf("response did not start: %v", err)
	}
	idle, err := dial(addr)
	if err != nil {
		return "", err
	}
	defer idle.Close()
	partial, err := dial(addr)
	if err != nil {
		return "", err
	}
	defer partial.Close()
	io.WriteString(partial, get[:len(get)/2])
	if err := s.until(t, func(t *trace) bool { return len(t.open) == 3 }); err != nil {
		return "", err
	}
	s.cmd.Process.Signal(syscall.SIGTERM)
	if err := readExact(ra, false); err != nil {
		return "", fmt.Errorf("the response in flight: %w", err)
	}
	for _, e := range []struct {
		r    io.Reader
		what string
	}{{ra, "after the response"}, {idle, "idle connection"}, {partial, "half a request"}} {
		if err := expectEOF(e.r, e.what); err != nil {
			return "", err
		}
	}
	summary, err := s.account(t, 3)
	if err == nil && t.sendsAtStop == 0 {
		// Without a send in flight at the stop, the scenario shows nothing
		// about sends surviving the shutdown.
		return "", fmt.Errorf("the response was sent completely before the stop arrived")
	}
	return summary, err
}

// deadlines checks the idle, head and body expiries end to end on two
// one-loop servers. On the first, the idle and head budgets are short and
// the body's is long; it holds three connections: one that sends nothing
// (the head's budget runs from accept), one with half a head, and one that
// got its response and sends nothing more (keep-alive). On the second, only
// the body's budget is short, so a connection holding a head and part of
// its body can be closed within the test's deadline only by the body's
// expiry. Each connection must see the server's close with no byte (after
// the response, for the keep-alive one): an expired head or body gets no
// 408, an idle connection is closed silently. Every connection is freed
// once, and each server stops gracefully.
func deadlines(path string) (string, error) {
	// The budgets: external peer deadlines (README, "Deadlines"); the short
	// ones end the scenario soon, the long ones exceed the test's deadline
	// below, so they cannot be what closed a connection. The closes are
	// awaited, not timed.
	const short, long = "100", "600000"
	first := []struct{ what, bytes string }{
		{"nothing sent", ""},
		{"half a head", get[:len(get)/2]},
		{"keep-alive after a response", get},
	}
	second := []struct{ what, bytes string }{
		{"a head and part of its body", "POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhe"},
	}
	var reports []string
	for _, run := range []struct {
		args  []string
		sends []struct{ what, bytes string }
	}{
		{[]string{"--idle-ms", short, "--head-ms", short, "--body-ms", long}, first},
		{[]string{"--idle-ms", long, "--head-ms", long, "--body-ms", short}, second},
	} {
		report, err := deadlineRun(path, run.args, run.sends)
		if err != nil {
			return "", err
		}
		reports = append(reports, report)
	}
	return strings.Join(reports, "; "), nil
}

func deadlineRun(path string, budgets []string, sends []struct{ what, bytes string }) (string, error) {
	s, err := start(path, append([]string{"1", "--trace"}, budgets...)...)
	if err != nil {
		return "", err
	}
	defer s.stop()
	t := newTrace()
	for _, sc := range sends {
		c, err := dial(s.addr)
		if err != nil {
			return "", err
		}
		defer c.Close()
		// delay: test deadline: bounds the wait for the server's close; its expiry fails the scenario.
		c.SetReadDeadline(time.Now().Add(30 * time.Second))
		r := bufio.NewReader(c)
		if _, err := io.WriteString(c, sc.bytes); err != nil {
			return "", fmt.Errorf("%s: %w", sc.what, err)
		}
		if sc.bytes == get {
			if err := readExact(r, false); err != nil {
				return "", fmt.Errorf("%s: %w", sc.what, err)
			}
		}
		if err := expectEOF(r, sc.what); err != nil {
			return "", err
		}
	}
	return s.account(t, int64(len(sends)))
}

// admission runs a one-loop server with --max-conns 2: two connections are
// served, a third one waits in the listen queue, and the server accepts it
// only after one of the two closed (its "open" follows a "free" in the
// trace; without the limit it would be accepted while both are open, before
// the client closes the first). A control run with --max-conns 3 must show
// that early accept, so the trace order is shown to detect a missing limit.
func admission(path string) (string, error) {
	summary, early, err := admit(path, "2")
	if err != nil {
		return "", err
	}
	if early {
		return "", fmt.Errorf("the third connection was accepted while two were open")
	}
	if _, early, err = admit(path, "3"); err != nil {
		return "", fmt.Errorf("control run with --max-conns 3: %w", err)
	}
	if !early {
		return "", fmt.Errorf("control run with --max-conns 3: the third connection was not accepted before a slot freed, so the scenario cannot detect a missing limit")
	}
	return summary + "; a control run without the limit accepted early", nil
}

// admit runs the admission scenario with `maxConns`; early reports whether
// the third connection was opened before any connection was freed.
func admit(path, maxConns string) (string, bool, error) {
	s, err := start(path, "1", "--max-conns", maxConns, "--trace")
	if err != nil {
		return "", false, err
	}
	addr := s.addr
	defer s.stop()
	t := newTrace()
	var cs [3]*net.TCPConn
	var rs [3]*bufio.Reader
	for i := range cs {
		if cs[i], err = dial(addr); err != nil {
			return "", false, err
		}
		defer cs[i].Close()
		rs[i] = bufio.NewReader(cs[i])
		io.WriteString(cs[i], get)
		if i < 2 {
			if err := readExact(rs[i], false); err != nil {
				return "", false, fmt.Errorf("connection %d: %w", i+1, err)
			}
		}
	}
	// A round trip on the second connection after the third one connected.
	io.WriteString(cs[1], get)
	if err := readExact(rs[1], false); err != nil {
		return "", false, fmt.Errorf("connection 2 again: %w", err)
	}
	cs[0].Close()
	if err := readExact(rs[2], false); err != nil {
		return "", false, fmt.Errorf("connection 3 after a slot freed: %w", err)
	}
	var early bool
	err = s.until(t, func(t *trace) bool {
		if len(t.open) == 3 && len(t.freed) == 0 {
			early = true
		}
		return len(t.open) == 3
	})
	if err != nil {
		return "", false, err
	}
	cs[1].Close()
	cs[2].Close()
	summary, err := s.account(t, 3)
	return summary, early, err
}

// crashPoint runs a one-loop server that kills itself with SIGKILL right
// after its `n`-th successful receive or send (crashArg), before Lean
// records it, and checks what the client saw: at most `most` bytes, a prefix
// of the response. A fresh server must then serve normally: nothing of the
// crashed process survives (README, "Production contract").
func crashPoint(path, crashArg string, n, most int, args ...string) (string, error) {
	s, err := start(path, append([]string{"1", crashArg, strconv.Itoa(n)}, args...)...)
	if err != nil {
		return "", err
	}
	c, err := dial(s.addr)
	if err != nil {
		s.stop()
		return "", err
	}
	io.WriteString(c, get)
	got, _ := io.ReadAll(c) // the kill closes the socket: EOF, or a reset
	c.Close()
	st := s.end()
	kind := strings.TrimPrefix(crashArg, "--crash-after-")
	if ws, ok := st.Sys().(syscall.WaitStatus); !ok || !ws.Signaled() || ws.Signal() != syscall.SIGKILL {
		return "", fmt.Errorf("server ended with %v, not by its SIGKILL: %s", st, tail(s.output))
	}
	if len(s.output) != 3 || !strings.HasPrefix(s.output[2], "crash "+kind+" ") {
		return "", fmt.Errorf("output %q, want listening on, ready and one crash %s line", s.output, kind)
	}
	const prefix = "HTTP/1.1 200 OK\r\nContent-Type: "
	if len(got) > most || !strings.HasPrefix(prefix, string(got)) {
		return "", fmt.Errorf("client saw %q; want a prefix of the response of at most %d bytes", got, most)
	}
	s2, err := start(path, "1", "--trace")
	if err != nil {
		return "", fmt.Errorf("restart: %w", err)
	}
	defer s2.stop()
	if err := exchange(s2.addr); err != nil {
		return "", fmt.Errorf("after the restart: %w", err)
	}
	summary, err := s2.account(newTrace(), 1)
	return fmt.Sprintf("client saw %d response bytes, %q; restarted server: %s", len(got), s.output[2], summary), err
}

// rssKiB is the resident set size of process pid, from ps(1), taken with
// transparent huge pages off (disableTHP).
func rssKiB(pid int) (int, error) {
	if err := thpOff(pid); err != nil {
		return 0, err
	}
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(out)))
}

// sendingBound, in KiB: the blocks README "Memory" derives for a connection
// sending a final response, the loop's connection (a 20,480-byte malloc
// block), the buffer (an exact copy of under 8,192 bytes, at most a
// 10,240-byte mimalloc block) and the response (capacity at most 65,536, an
// 81,920-byte block), plus an allowance of 2 KiB, not derived, for the
// state's small Lean objects and the allocators' metadata. The adapter is at
// its shared `init` then. A measurement over it shows the accounting misses
// something.
const sendingBound = (20480 + 10240 + 81920 + 2048) / 1024

// memory measures the retained memory of connections holding a request
// head: 1000 connections each send an 8,000-byte head with
// `Expect: 100-continue` and a body still to come; the interim response is
// the event that shows the server buffered the head and waits. It reports
// the growth of the resident set per connection and checks no bound: the
// bound of the adapter's state, which such a connection holds, is on live
// blocks and checked in lsrv-test; how many of the freed ones stay resident
// is not derived (README, "Memory").
func memory(path string) (string, error) {
	const n = 1000
	s, err := start(path, "1", "--max-conns", "1100")
	if err != nil {
		return "", err
	}
	defer s.stop()
	addr := s.addr
	base, err := rssKiB(s.cmd.Process.Pid)
	if err != nil {
		return "", err
	}
	fill := strings.Repeat("a", 8000)
	conns := make([]*net.TCPConn, n)
	defer func() {
		for _, c := range conns {
			if c != nil {
				c.Close()
			}
		}
	}()
	err = parallel(n, 32, func(i int) error {
		c, err := dial(addr)
		if err != nil {
			return err
		}
		conns[i] = c
		io.WriteString(c, "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 8192\r\nX: "+fill+"\r\n\r\n")
		interim := make([]byte, len(continueBytes))
		if _, err := io.ReadFull(c, interim); err != nil || string(interim) != continueBytes {
			return fmt.Errorf("interim response %q, %v", interim, err)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	held, err := rssKiB(s.cmd.Process.Pid)
	if err != nil {
		return "", err
	}
	per := float64(held-base) / n
	return fmt.Sprintf("resident set %d KiB idle, %d KiB with %d heads held: %.1f KiB per connection (a measurement; no bound)", base, held, n, per), nil
}

// tcpQueues maps each established TCP connection of processes `pids`, by
// its "local->foreign" address pair, to its receive and send queue lengths:
// bytes the kernel holds that the process has not read, and bytes the process
// wrote that the peer has not acknowledged. On macOS from lsof(8)'s -T q (QR,
// QS); macOS's `netstat -an -p tcp` lists no TCP sockets (seen on Darwin
// 27.2). On Linux from /proc (procQueues). checkQueues checks either against
// connections whose queues are known.
func tcpQueues(pids ...int) (map[string][2]int, error) {
	if runtime.GOOS == "linux" {
		return procQueues(pids)
	}
	ps := make([]string, len(pids))
	for i, p := range pids {
		ps[i] = strconv.Itoa(p)
	}
	// -F: one field per line, a file's name ("n") before its TCP info ("T").
	out, err := exec.Command("lsof", "-nP", "-a", "-p", strings.Join(ps, ","), "-iTCP", "-sTCP:ESTABLISHED", "-Tqs", "-F", "nT").Output()
	if err != nil {
		return nil, err
	}
	qs := map[string][2]int{}
	seen := map[string]int{} // per name: bit 1 QR read, bit 2 QS read
	name := ""
	for _, line := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(line, "n"):
			name = line[1:]
		case strings.HasPrefix(line, "TQR="), strings.HasPrefix(line, "TQS="):
			v, err := strconv.Atoi(line[4:])
			if err != nil || name == "" {
				return nil, fmt.Errorf("lsof line %q", line)
			}
			q, bit := qs[name], 1
			if line[2] == 'R' {
				q[0] = v
			} else {
				q[1], bit = v, 2
			}
			qs[name] = q
			seen[name] |= bit
		}
	}
	// A connection without both sizes is left out, so a caller finds it
	// missing instead of reading a size of 0 that lsof never reported.
	for name, bits := range seen {
		if bits != 3 {
			delete(qs, name)
		}
	}
	return qs, nil
}

// procQueues is tcpQueues on Linux. Each process's sockets are read from
// /proc/PID/net/tcp and tcp6, which list the sockets of that process's
// network namespace, and kept when established (st 01) and when their inode
// is one of the process's descriptors (/proc/PID/fd, "socket:[INODE]"), so
// a connection is attributed to the process that holds it, not only to its
// addresses. rx_queue is rcv_nxt - copied_seq and tx_queue is write_seq -
// snd_una (get_tcp4_sock in Linux's net/ipv4/tcp_ipv4.c, and
// get_tcp6_sock): bytes received and not read, and bytes written and not
// acknowledged, as lsof's QR and QS. An IPv4-mapped IPv6 address is
// written as IPv4, as Go writes it.
func procQueues(pids []int) (map[string][2]int, error) {
	qs := map[string][2]int{}
	for _, pid := range pids {
		dir := fmt.Sprintf("/proc/%d/fd", pid)
		fds, err := os.ReadDir(dir)
		if err != nil {
			return nil, err
		}
		inodes := map[string]bool{}
		for _, fd := range fds {
			l, err := os.Readlink(filepath.Join(dir, fd.Name()))
			if errors.Is(err, os.ErrNotExist) {
				continue // closed since the listing
			}
			if err != nil {
				return nil, err
			}
			if in, ok := strings.CutPrefix(l, "socket:["); ok {
				inodes[strings.TrimSuffix(in, "]")] = true
			}
		}
		for _, table := range []string{"tcp", "tcp6"} {
			name := fmt.Sprintf("/proc/%d/net/%s", pid, table)
			data, err := os.ReadFile(name)
			if table == "tcp6" && errors.Is(err, os.ErrNotExist) {
				continue // a kernel without IPv6
			}
			if err != nil {
				return nil, err
			}
			lines := strings.Split(string(data), "\n")
			for _, line := range lines[1:] { // after the heading
				// sl local_address rem_address st tx_queue:rx_queue tr:tm->when
				// retrnsmt uid timeout inode ...
				f := strings.Fields(line)
				if len(f) == 0 {
					continue
				}
				if len(f) < 10 {
					return nil, fmt.Errorf("%s line %q", name, line)
				}
				if f[3] != "01" || !inodes[f[9]] {
					continue
				}
				local, err1 := procAddr(f[1])
				remote, err2 := procAddr(f[2])
				tx, rx, ok := strings.Cut(f[4], ":")
				t, err3 := strconv.ParseUint(tx, 16, 32)
				r, err4 := strconv.ParseUint(rx, 16, 32)
				if err := errors.Join(err1, err2, err3, err4); err != nil || !ok {
					return nil, fmt.Errorf("%s line %q: %v", name, line, err)
				}
				qs[local+"->"+remote] = [2]int{int(r), int(t)}
			}
		}
	}
	return qs, nil
}

// procAddr reads an address of /proc/net/tcp or tcp6, "ADDR:PORT" in hex:
// the address as 32-bit words, each the network-order bytes read as a
// native-order integer, and the port as a number.
func procAddr(s string) (string, error) {
	h, p, ok := strings.Cut(s, ":")
	port, err := strconv.ParseUint(p, 16, 16)
	if !ok || err != nil || (len(h) != 8 && len(h) != 32) {
		return "", fmt.Errorf("address %q", s)
	}
	b := make([]byte, len(h)/2)
	for i := 0; i < len(h); i += 8 {
		w, err := strconv.ParseUint(h[i:i+8], 16, 32)
		if err != nil {
			return "", fmt.Errorf("address %q", s)
		}
		binary.NativeEndian.PutUint32(b[i/2:], uint32(w))
	}
	a, _ := netip.AddrFromSlice(b)
	return netip.AddrPortFrom(a.Unmap(), uint16(port)).String(), nil
}

// checkQueues checks tcpQueues against connections of this process, over
// loopback, whose queues are known, before a scenario relies on it: each of
// three servers has not read k bytes its client wrote (1,000, 2,000 and
// 3,000; awaitBytes shows they arrived) and has written nothing, so its
// socket must show exactly k unread and nothing unacknowledged, and its
// client's nothing unread. A fourth server, with a send buffer far larger
// than its client's receive buffer, writes until its send would block to a
// client that writes nothing and never reads: of the w bytes it wrote, its
// socket's unacknowledged and the client's unread (from a second, later
// reading, as in memoryFull) must each be more than none and at most w, and
// together at least w (a byte received and not yet acknowledged counts
// twice), and the client must have nothing unacknowledged.
func checkQueues() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer ln.Close()
	var cs, ss []*net.TCPConn
	defer func() {
		for _, c := range append(cs, ss...) {
			c.Close()
		}
	}()
	// The clients' receive buffer is set before the handshake, so the window
	// they advertise is as small.
	d := net.Dialer{Control: func(_, _ string, rc syscall.RawConn) error {
		var serr error
		err := rc.Control(func(fd uintptr) {
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF, 8192)
		})
		return errors.Join(err, serr)
	}}
	for range 4 {
		c, err := d.Dial("tcp", ln.Addr().String())
		if err != nil {
			return err
		}
		cs = append(cs, c.(*net.TCPConn))
		s, err := ln.Accept() // the connection just dialled: one at a time
		if err != nil {
			return err
		}
		ss = append(ss, s.(*net.TCPConn))
	}
	sizes := []int{1000, 2000, 3000}
	for i, k := range sizes {
		if _, err := cs[i].Write(bytes.Repeat([]byte{'a'}, k)); err != nil {
			return err
		}
		if err := awaitBytes(ss[i], k); err != nil {
			return err
		}
	}
	if err := ss[3].SetWriteBuffer(1 << 20); err != nil {
		return err
	}
	w, err := fillSend(ss[3])
	if err != nil {
		return err
	}
	first, err := tcpQueues(os.Getpid())
	if err != nil {
		return err
	}
	later, err := tcpQueues(os.Getpid())
	if err != nil {
		return err
	}
	pair := func(i int, qs map[string][2]int) (c, s [2]int, err error) {
		cl, sv := cs[i].LocalAddr().String(), cs[i].RemoteAddr().String()
		c, ok1 := qs[cl+"->"+sv]
		s, ok2 := qs[sv+"->"+cl]
		if !ok1 || !ok2 {
			err = fmt.Errorf("control connection %d (%s): not among the established connections read", i, cl)
		}
		return
	}
	for i, k := range sizes {
		c, s, err := pair(i, first)
		if err != nil {
			return err
		}
		if s[0] != k || s[1] != 0 || c[0] != 0 {
			return fmt.Errorf("control connection %d: the server's queues read %d unread and %d unacknowledged, the client's %d unread; want %d, 0 and 0", i, s[0], s[1], c[0], k)
		}
	}
	_, s, err := pair(3, first)
	if err != nil {
		return err
	}
	c, _, err := pair(3, later)
	if err != nil {
		return err
	}
	if s[1] == 0 || s[1] > w || c[0] == 0 || c[0] > w || s[1]+c[0] < w || c[1] != 0 {
		// The kernel may cap or grow either buffer (Linux: net.core.wmem_max;
		// macOS grows the receive buffer): a receiver that took every byte
		// leaves nothing unacknowledged, so the sizes it took are reported.
		return fmt.Errorf("control connection 3: %d bytes written; the server's queue reads %d unacknowledged, the client's %d unread and %d unacknowledged (send buffer %s, receive buffer %s)", w, s[1], c[0], c[1], sockBuffer(ss[3], syscall.SO_SNDBUF), sockBuffer(cs[3], syscall.SO_RCVBUF))
	}
	return nil
}

// sockBuffer describes c's socket option opt (SO_SNDBUF or SO_RCVBUF) as
// the kernel took it: its size, or why it could not be read.
func sockBuffer(c *net.TCPConn, opt int) string {
	rc, err := c.SyscallConn()
	if err != nil {
		return "unread: " + err.Error()
	}
	var v int
	var gerr error
	err = rc.Control(func(fd uintptr) {
		v, gerr = syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, opt)
	})
	if err := errors.Join(err, gerr); err != nil {
		return "unread: " + err.Error()
	}
	return strconv.Itoa(v) + " bytes"
}

// fillSend writes to c until its send would block and returns the bytes it
// wrote.
func fillSend(c *net.TCPConn) (int, error) {
	rc, err := c.SyscallConn()
	if err != nil {
		return 0, err
	}
	b := make([]byte, 65536)
	w := 0
	var werr error
	err = rc.Write(func(fd uintptr) bool {
		for {
			n, err := syscall.Write(int(fd), b)
			if err == syscall.EAGAIN {
				return true
			}
			if err != nil {
				werr = err
				return true
			}
			w += n
		}
	})
	if err == nil {
		err = werr
	}
	return w, err
}

// awaitBytes waits until c has received at least k bytes it has not read,
// without reading them (a peek), so the receive window it advertises stays
// as small. The peer must not close before it sent k bytes: after fewer and
// the end of the stream, no arrival makes c readable again.
func awaitBytes(c *net.TCPConn, k int) error {
	rc, err := c.SyscallConn()
	if err != nil {
		return err
	}
	var n int
	var perr error
	b := make([]byte, k)
	err = rc.Read(func(fd uintptr) bool {
		n, _, perr = syscall.Recvfrom(int(fd), b, syscall.MSG_PEEK)
		// Fewer than k: wait for the next arrival, which makes c readable.
		return perr != syscall.EAGAIN && !(perr == nil && n > 0 && n < k)
	})
	if err == nil {
		err = perr
	}
	if err == nil && n == 0 {
		err = io.EOF
	}
	return err
}

// memSnapDir, when set (-memsnap), is where memoryFull writes the server's
// allocator statistics at each of its two measurements, for attributing the
// growth between them (README, "Memory"): vmmap -summary (resident size per
// region type, and the malloc zones' allocated bytes) and heap -s (the
// malloc blocks by size). Lean's objects come from the toolchain's mimalloc,
// whose mappings carry VM tag 100 (mimalloc.h, mi_option_os_tag), which
// vmmap names IOAccelerator; heap sees only the malloc zones, which hold the
// loop's connections (std.heap.c_allocator, zig/src/serve.zig).
var memSnapDir string

// memSnapshot writes those statistics of process pid, taken with conns
// connections open, to memSnapDir; it does nothing when memSnapDir is empty.
func memSnapshot(pid, conns int) error {
	if memSnapDir == "" {
		return nil
	}
	p := strconv.Itoa(pid)
	for _, a := range [][]string{{"vmmap", "-summary", p}, {"heap", "-s", p}} {
		out, err := exec.Command(a[0], a[1:]...).Output()
		if err != nil {
			var stderr []byte
			if ee, ok := err.(*exec.ExitError); ok {
				stderr = ee.Stderr
			}
			return fmt.Errorf("%s with %d connections: %w; %s", a[0], conns, err, bytes.TrimSpace(stderr))
		}
		name := filepath.Join(memSnapDir, fmt.Sprintf("%s-%d.txt", a[0], conns))
		if err := os.WriteFile(name, out, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// memoryFull measures the retained memory of connections each holding a
// whole response being sent and a buffered tail of pipelined bytes, the most
// Lean holds per connection at once when it sends (README, "Memory"). A
// connection takes its input only while it is not sending, and the loop
// receives at most 8,192 bytes (recv_cap, zig/src/serve.zig) at a time, so
// while it sends a response its buffer holds at most the rest of the receive
// that completed the request: less than 8,192 bytes, never `inCap`. Each
// client writes exactly 8,192 bytes at once: `gets` pipelined GETs of the
// 60,001-byte body, then the start of a request that never completes. It
// never reads, so the server's sends stall once the kernel holds what it
// can. Before the measurement the client has
// seen the first response's first byte (a peek), and lsof shows for every
// connection nothing queued towards the server in either socket: the server
// has read all 8,192 bytes, and the client sends no more. After it, lsof
// shows that the server has not sent all but the last GET's responses. So at
// the measurement each connection had read all 8,192 bytes, and since a
// complete GET was still unanswered it was sending one whole response
// (Conn.step answers each completed send at once with the next one) with
// those bytes less the GETs it consumed buffered. The GETs consumed are
// bounded by the response bytes sent, so the summary gives the fewest bytes
// any connection can have held buffered. Not excluded by these observations:
// a connection whose 8,192 bytes arrived in two receives, the second taken
// from the socket but not yet handed to Lean at the measurement, which then
// held its second part in the loop's receive buffer and no response. The
// queues show what the sockets hold, not the connection's state; only an
// acknowledgement from the server would. On macOS and Linux (tcpQueues),
// after checkQueues.
func memoryFull(path string) (string, error) {
	// 100 connections: the kernel holds hundreds of KB of stalled responses
	// per connection, and 200 already made macOS deny network memory
	// ("requests for memory denied" in netstat -m), 1,000 to a failed send.
	const n = 100
	const gets = 100
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		return "skipped: the socket queues are read on macOS and Linux only", nil
	}
	if err := checkQueues(); err != nil {
		return "", fmt.Errorf("the socket queues read wrong: %w", err)
	}
	s, err := start(path, "1", "--max-conns", "1100")
	if err != nil {
		return "", err
	}
	defer s.stop()
	addr := s.addr
	// The keep-alive response's size on the wire (its head and the fixture's
	// body), from one exchange before the baseline.
	c0, err := dial(addr)
	if err != nil {
		return "", err
	}
	io.WriteString(c0, get)
	r0 := bufio.NewReader(c0)
	respSize := bodySize
	for {
		line, err := r0.ReadString('\n')
		if err != nil {
			c0.Close()
			return "", err
		}
		respSize += len(line)
		if line == "\r\n" {
			break
		}
	}
	got := make([]byte, bodySize)
	_, err = io.ReadFull(r0, got)
	c0.Close()
	if err != nil || !bytes.Equal(got, body) || r0.Buffered() != 0 {
		return "", fmt.Errorf("the response to a GET is not the fixture's body: %v", err)
	}
	base, err := rssKiB(s.cmd.Process.Pid)
	if err != nil {
		return "", err
	}
	const write = 8192 // recv_cap
	payload := strings.Repeat(get, gets) + "GET / HTTP/1.1\r\nHost: a\r\nX: "
	payload += strings.Repeat("a", write-len(payload))
	conns := make([]*net.TCPConn, n)
	defer func() {
		for _, c := range conns {
			if c != nil {
				c.Close()
			}
		}
	}()
	// fill opens conns[lo:hi], each writing the payload and seeing its first
	// response byte, then checks, for conns[:hi], that every byte the client
	// wrote has reached the server's socket (nothing unacknowledged) and
	// then, in a later reading, that the server has read it all (nothing
	// unread), and returns the server's resident set.
	fill := func(lo, hi int) (int, error) {
		err := parallel(hi-lo, 32, func(k int) error {
			c, err := dial(addr)
			if err != nil {
				return err
			}
			conns[lo+k] = c
			if _, err := io.WriteString(c, payload); err != nil {
				return err
			}
			if err := awaitBytes(c, 1); err != nil {
				return fmt.Errorf("first response byte: %w", err)
			}
			return nil
		})
		if err != nil {
			return 0, err
		}
		for _, side := range []int{0, 1} {
			qs, err := tcpQueues(s.cmd.Process.Pid, os.Getpid())
			if err != nil {
				return 0, fmt.Errorf("socket queues: %w", err)
			}
			for i, c := range conns[:hi] {
				cl, sv := c.LocalAddr().String(), c.RemoteAddr().String()
				cq, ok1 := qs[cl+"->"+sv]
				sq, ok2 := qs[sv+"->"+cl]
				if !ok1 || !ok2 {
					return 0, fmt.Errorf("connection %d (%s): not among the established connections read", i, cl)
				}
				if side == 0 && cq[1] != 0 {
					return 0, fmt.Errorf("connection %d: %d bytes of the client's unacknowledged", i, cq[1])
				}
				if side == 1 && sq[0] != 0 {
					return 0, fmt.Errorf("connection %d: %d bytes unread by the server; it has not read all %d bytes", i, sq[0], write)
				}
			}
		}
		if err := memSnapshot(s.cmd.Process.Pid, hi); err != nil {
			return 0, err
		}
		return rssKiB(s.cmd.Process.Pid)
	}
	// Two measurements, after half the connections and after all: their
	// difference is the resident set the second half added, without the
	// apparent fixed component that (all - idle) / n would spread over the
	// connections (about 500 KiB on the M1).
	half, err := fill(0, n/2)
	if err != nil {
		return "", err
	}
	held, err := fill(n/2, n)
	if err != nil {
		return "", err
	}
	// After it: the server has not sent all but the last response. Bytes it
	// sent are unacknowledged in its socket or unread in the client's. Each
	// reading takes the sockets one by one, so the client's is taken from a
	// second, later reading: the client never reads, so its count only grows,
	// and the sum is never below what the server had sent when its own socket
	// was read (a byte received and not yet acknowledged counts twice).
	after, err := tcpQueues(s.cmd.Process.Pid, os.Getpid())
	if err != nil {
		return "", fmt.Errorf("socket queues: %w", err)
	}
	later, err := tcpQueues(s.cmd.Process.Pid, os.Getpid())
	if err != nil {
		return "", fmt.Errorf("socket queues: %w", err)
	}
	least := write // the fewest bytes any connection held buffered
	for i, c := range conns {
		cl, sv := c.LocalAddr().String(), c.RemoteAddr().String()
		cq, ok1 := later[cl+"->"+sv]
		sq, ok2 := after[sv+"->"+cl]
		if !ok1 || !ok2 {
			return "", fmt.Errorf("connection %d (%s): not among the established connections read", i, cl)
		}
		sent := cq[0] + sq[1]
		if sent >= (gets-1)*respSize {
			return "", fmt.Errorf("connection %d: up to %d response bytes sent, of %d responses; the sends did not stall", i, sent, gets)
		}
		least = min(least, write-(sent/respSize+1)*len(get))
	}
	per := float64(held-half) / (n - n/2)
	summary := fmt.Sprintf("resident set %d KiB idle, %d KiB with %d and %d KiB with %d connections, each with all its bytes read and not all responses sent (so sending a %d-byte response with at least %d bytes buffered, unless a receive had not reached Lean): %.1f KiB per added connection (bound %d KiB)",
		base, half, n/2, held, n, respSize, least, per, sendingBound)
	if per > sendingBound {
		return "", fmt.Errorf("%s: over the bound", summary)
	}
	return summary, nil
}

// expectHead is a request head asking for `100-continue` before a body of
// `maxBodyBytes` (Server/Wire.lean), with `target` and the fields `extra`
// ("Name: value\r\n" each) besides Host, Expect and Content-Length.
func expectHead(target, extra string) string {
	return "POST " + target + " HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 8192\r\n" + extra + "\r\n"
}

// readInterim reads the interim response from r: the event that shows the
// server has parsed a head and waits for its body.
func readInterim(r io.Reader) error {
	interim := make([]byte, len(continueBytes))
	if _, err := io.ReadFull(r, interim); err != nil || string(interim) != continueBytes {
		return fmt.Errorf("interim response %q, %v", interim, err)
	}
	return nil
}

// awaitRead waits until lsof shows, for every connection of conns, nothing
// of the client's unacknowledged and nothing unread by the server: the
// server has taken every byte the clients wrote from its sockets. The
// producer is the server's loop receiving; after `tries` readings without
// it, it reports what was still queued. That a byte left the socket does not show that Lean has been
// handed it: a receive the loop has completed but not yet passed to
// `Conn.step` at the measurement is not excluded (as in memoryFull).
func awaitRead(pid int, conns []*net.TCPConn) error {
	const tries = 200
	queued := ""
	for range tries {
		qs, err := tcpQueues(pid, os.Getpid())
		if err != nil {
			return fmt.Errorf("lsof: %w", err)
		}
		queued = ""
		for i, c := range conns {
			cl, sv := c.LocalAddr().String(), c.RemoteAddr().String()
			cq, ok1 := qs[cl+"->"+sv]
			sq, ok2 := qs[sv+"->"+cl]
			if !ok1 || !ok2 {
				return fmt.Errorf("connection %d (%s): not among lsof's established connections", i, cl)
			}
			if cq[1] != 0 || sq[0] != 0 {
				queued = fmt.Sprintf("connection %d: %d bytes of the client's unacknowledged, %d unread by the server", i, cq[1], sq[0])
				break
			}
		}
		if queued == "" {
			return nil
		}
	}
	return fmt.Errorf("after %d lsof readings, %s", tries, queued)
}

// held measures what n connections retain in a state each reaches through
// hold (which sees its connection and ends at an event showing the server
// holds that state, or, when lsofSettle, after which awaitRead must show the
// server has read every byte). Two measurements, after n/2 and after n
// connections, as in memoryFull: their difference per added connection,
// without the fixed component. args go to the server.
func held(path string, args []string, n int, lsofSettle bool, hold func(c *net.TCPConn) error) (string, error) {
	if lsofSettle && runtime.GOOS != "darwin" {
		return "skipped: the socket queues it waits on are read with lsof, on macOS only (Linux's are qualified for the scenario with 100 connections sending responses only)", nil
	}
	s, err := start(path, append(args, "--max-conns", strconv.Itoa(n+100))...)
	if err != nil {
		return "", err
	}
	defer s.stop()
	conns := make([]*net.TCPConn, n)
	defer func() {
		for _, c := range conns {
			if c != nil {
				c.Close()
			}
		}
	}()
	fill := func(lo, hi int) (int, error) {
		err := parallel(hi-lo, 32, func(k int) error {
			c, err := dial(s.addr)
			if err != nil {
				return err
			}
			conns[lo+k] = c
			return hold(c)
		})
		if err != nil {
			return 0, err
		}
		if lsofSettle {
			if err := awaitRead(s.cmd.Process.Pid, conns[:hi]); err != nil {
				return 0, err
			}
		}
		return rssKiB(s.cmd.Process.Pid)
	}
	half, err := fill(0, n/2)
	if err != nil {
		return "", err
	}
	all, err := fill(n/2, n)
	if err != nil {
		return "", err
	}
	per := float64(all-half) / float64(n-n/2)
	return fmt.Sprintf("resident set %d KiB with %d and %d KiB with %d connections: %.1f KiB per added connection", half, n/2, all, n, per), nil
}

// adapterScenario is a scenario of held for a state in which a connection
// holds the adapter's state for an incomplete request: the server's
// arguments, the connections, whether awaitRead settles it, and hold. It
// fails only when a connection does not reach that state; the memory it
// reports is checked against no bound, since the adapter's is on live blocks,
// checked in lsrv-test, not on the resident set (README, "Memory": these
// measurements falsified the earlier 98 KiB).
func adapterScenario(args []string, n int, lsofSettle bool, hold func(c *net.TCPConn) error) func(path string) (string, error) {
	return func(path string) (string, error) {
		summary, err := held(path, args, n, lsofSettle, hold)
		if err != nil || strings.HasPrefix(summary, "skipped: ") {
			return summary, err
		}
		return summary + " (a measurement; no bound)", nil
	}
}

// fieldsHead: the most fields H1 accepts (`maxHeaders`, 100), short ones.
func fieldsHead() string {
	var b strings.Builder
	for i := range 97 {
		fmt.Fprintf(&b, "a%d: b\r\n", i)
	}
	return expectHead("/echo", b.String())
}

// longFieldsHead: 97 fields of 72-byte values, a head of nearly
// `maxHeadBytes` in lines short enough that 7-byte receives do not make H1's
// reparsing of an unfinished line slow.
func longFieldsHead() string {
	var b strings.Builder
	for i := range 97 {
		fmt.Fprintf(&b, "a%02d: %s\r\n", i, strings.Repeat("v", 72))
	}
	return expectHead("/echo", b.String())
}

func holdHead(h string) func(c *net.TCPConn) error {
	return func(c *net.TCPConn) error {
		if _, err := io.WriteString(c, h); err != nil {
			return err
		}
		return readInterim(c)
	}
}

// holdLine sends a complete request and reads its response, the event that
// shows the server accepted the connection (lsof sees no connection still in
// the listen queue), then the start of a request, l, and nothing more; that
// the server read l is lsof's to show (lsofSettle).
func holdLine(l string) func(c *net.TCPConn) error {
	return func(c *net.TCPConn) error {
		if _, err := io.WriteString(c, "POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n"); err != nil {
			return err
		}
		resp, err := http.ReadResponse(bufio.NewReader(c), &http.Request{Method: "POST"})
		if err != nil {
			return err
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			return fmt.Errorf("status %d", resp.StatusCode)
		}
		_, err = io.WriteString(c, l)
		return err
	}
}

// holdBody sends head h, waits for the interim response, then sends all but
// the last byte of the 8,192-byte body.
func holdBody(h string) func(c *net.TCPConn) error {
	return func(c *net.TCPConn) error {
		if err := holdHead(h)(c); err != nil {
			return err
		}
		_, err := io.WriteString(c, strings.Repeat("b", 8191))
		return err
	}
}

// holdAfterPipelined sends k pipelined requests with empty bodies, then an
// incomplete one in the same write, and reads the k responses and the
// interim response.
func holdAfterPipelined(k int) func(c *net.TCPConn) error {
	const echo = "POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n"
	h := strings.Repeat(echo, k) + expectHead("/echo", "X: "+strings.Repeat("a", 4000)+"\r\n")
	return func(c *net.TCPConn) error {
		if _, err := io.WriteString(c, h); err != nil {
			return err
		}
		r := bufio.NewReader(c)
		for i := range k {
			resp, err := http.ReadResponse(r, &http.Request{Method: "POST"})
			if err != nil {
				return fmt.Errorf("response %d: %w", i, err)
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode != 200 {
				return fmt.Errorf("response %d: status %d", i, resp.StatusCode)
			}
		}
		if err := readInterim(r); err != nil {
			return err
		}
		if r.Buffered() != 0 {
			return fmt.Errorf("%d bytes after the interim response", r.Buffered())
		}
		return nil
	}
}

type scenario struct {
	name string
	args []string
	// injects: the server injects failures, and the trace must show both
	// receive and send failures injected.
	injects bool
	// run drives the server and returns how many connections it made.
	run func(addr string) (int64, string, error)
	// custom, when set, replaces args and run: it starts its own servers and
	// returns a summary.
	custom func(path string) (string, error)
	// continues: the scenario needs the server to answer
	// `Expect: 100-continue`, which the hand-written comparator does not.
	continues bool
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
	fixture := flag.String("fixture", ".lake/build/bin/lsrv-fixture", "fixture server executable")
	noContinue := flag.Bool("no-continue", false, "the fixture does not answer Expect: 100-continue (lsrv-fixture-hand); skip the scenarios that need it")
	flag.StringVar(&memSnapDir, "memsnap", "", "directory for the server's allocator statistics (vmmap, heap) at the measurements of the scenario with 100 connections sending responses; macOS only")
	only := flag.String("only", "", "run only the scenarios whose name contains this text")
	flag.Parse()
	if err := disableTHP(); err != nil {
		fmt.Println("FAIL", err)
		os.Exit(1)
	}
	scenarios := []scenario{
		{"large responses, operations of at most 7 bytes", []string{"2", "--chunk", "7", "--trace"}, false, exchanges(8), nil, false},
		{"large responses, full-size operations", []string{"2", "--trace"}, false, exchanges(16), nil, false},
		{"every 29th receive and every 29th send fail", []string{"2", "--fail-every", "29", "--trace"}, true, failures, nil, false},
		{"connection churn with resets", []string{"4", "--trace"}, false, churn, nil, false},
		{"Expect: 100-continue and a response over the bound, operations of at most 7 bytes", []string{"2", "--chunk", "7", "--trace"}, false, expectations, nil, true},
		{"graceful shutdown with a response in flight, an idle and a partial connection", nil, false, nil, shutdown, false},
		{"admission: at most 2 connections", nil, false, nil, admission, false},
		{"deadlines: idle, head and body expire and close", nil, false, nil, deadlines, false},
		{"crash after the first receive", nil, false, nil, func(p string) (string, error) {
			return crashPoint(p, "--crash-after-recv", 1, 0)
		}, false},
		{"crash after the third 7-byte send", nil, false, nil, func(p string) (string, error) {
			return crashPoint(p, "--crash-after-send", 3, 21, "--chunk", "7")
		}, false},
		{"memory of 1000 connections holding a head", nil, false, nil, memory, true},
		{"memory of 100 connections each sending a response with a pipelined tail buffered", nil, false, nil, memoryFull, false},
		{"memory of 400 connections holding a head of 100 short fields", nil, false, nil, adapterScenario([]string{"1"}, 400, false, holdHead(fieldsHead())), true},
		{"memory of 400 connections holding all but one byte of a maximum body", nil, false, nil, adapterScenario([]string{"1"}, 400, true, holdBody(expectHead("/echo", ""))), true},
		{"memory of 100 connections holding a nearly maximum head and all but one body byte, received 7 bytes at a time", nil, false, nil, adapterScenario([]string{"1", "--chunk", "7"}, 100, true, holdBody(longFieldsHead())), true},
		{"memory of 400 connections holding an incomplete request after 50 pipelined ones", nil, false, nil, adapterScenario([]string{"1"}, 400, false, holdAfterPipelined(50)), true},
		{"memory of 400 connections holding a head whose target has 4,000 path segments", nil, false, nil, adapterScenario([]string{"1"}, 400, false, holdHead(expectHead("/"+strings.Repeat("a/", 3999)+"a", ""))), true},
		{"memory of 400 connections holding a head whose target has 4,000 query parameters", nil, false, nil, adapterScenario([]string{"1"}, 400, false, holdHead(expectHead("/echo?"+strings.Repeat("a&", 3999)+"a", ""))), true},
		// The target with the most elements per byte, as long as the request
		// line allows (8,192 bytes): its live blocks are the largest lsrv-test
		// finds. H1 keeps it from the end of the line.
		{"memory of 400 connections holding a request line whose target has 8,176 empty query parameters", nil, false, nil, adapterScenario([]string{"1"}, 400, true, holdLine("GET /?"+strings.Repeat("&", 8175)+" HTTP/1.1\r\n")), false},
	}
	failed, ran := 0, 0
	for _, sc := range scenarios {
		if !strings.Contains(sc.name, *only) {
			continue
		}
		if sc.continues && *noContinue {
			fmt.Printf("skipped %s: the fixture does not answer Expect: 100-continue\n", sc.name)
			continue
		}
		ran++
		if err := runScenario(*fixture, sc); err != nil {
			fmt.Printf("FAIL %s: %v\n", sc.name, err)
			failed++
		}
	}
	fmt.Printf("%d of %d boundary scenarios failed\n", failed, ran)
	if failed > 0 {
		os.Exit(1)
	}
}

func runScenario(path string, sc scenario) error {
	if sc.custom != nil {
		summary, err := sc.custom(path)
		if err == nil && strings.HasPrefix(summary, "skipped: ") {
			fmt.Printf("skipped %s: %s\n", sc.name, strings.TrimPrefix(summary, "skipped: "))
		} else if err == nil {
			fmt.Printf("ok %s: %s\n", sc.name, summary)
		}
		return err
	}
	s, err := start(path, sc.args...)
	if err != nil {
		return err
	}
	defer s.stop()
	connects, note, err := sc.run(s.addr)
	if err != nil {
		s.stop()
		return fmt.Errorf("%w; server output: %s", err, tail(s.output))
	}
	t := newTrace()
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
