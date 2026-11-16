// Tests of the Zig/Lean boundary (zig/src/serve.zig, glue.c,
// Server/Conn.lean) over real sockets. Each scenario starts a server
// executable with the loop's test settings (--chunk, --fail-every, --trace,
// --max-conns, --crash-after-recv, --crash-after-send), drives connections
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
	stopped          int
	// Sends in flight when a loop's stop arrived (its "stop R S" lines).
	sendsAtStop uint64
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
	case len(f) == 3 && f[0] == "stop":
		t.sendsAtStop += num(2)
	case line == "stopped":
		t.stopped++
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
// and the server's close.
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
	return 2, "", expectEOF(r2, "after the 500")
}

// shutdown sends SIGTERM to a one-loop server while it holds three
// connections: one in the middle of a 60,001-byte response sent 7 bytes per
// operation, one idle, one with half a request. The response must arrive
// whole, then every connection must see the server's close with nothing
// else, and the process must stop gracefully.
func shutdown(path, addr string) (string, error) {
	s, err := start(path, "1", "--chunk", "7", "--trace")
	if err != nil {
		return "", err
	}
	defer s.stop()
	t := newTrace(false)
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

// admission runs a one-loop server with --max-conns 2: two connections are
// served, a third one waits in the listen queue, and the server accepts it
// only after one of the two closed (its "open" follows a "free" in the
// trace; without the limit it would be accepted while both are open, before
// the client closes the first). A control run with --max-conns 3 must show
// that early accept, so the trace order is shown to detect a missing limit.
func admission(path, addr string) (string, error) {
	summary, early, err := admit(path, addr, "2")
	if err != nil {
		return "", err
	}
	if early {
		return "", fmt.Errorf("the third connection was accepted while two were open")
	}
	if _, early, err = admit(path, addr, "3"); err != nil {
		return "", fmt.Errorf("control run with --max-conns 3: %w", err)
	}
	if !early {
		return "", fmt.Errorf("control run with --max-conns 3: the third connection was not accepted before a slot freed, so the scenario cannot detect a missing limit")
	}
	return summary + "; a control run without the limit accepted early", nil
}

// admit runs the admission scenario with `maxConns`; early reports whether
// the third connection was opened before any connection was freed.
func admit(path, addr, maxConns string) (string, bool, error) {
	s, err := start(path, "1", "--max-conns", maxConns, "--trace")
	if err != nil {
		return "", false, err
	}
	defer s.stop()
	t := newTrace(false)
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
func crashPoint(path, addr, crashArg string, n, most int, args ...string) (string, error) {
	s, err := start(path, append([]string{"1", crashArg, strconv.Itoa(n)}, args...)...)
	if err != nil {
		return "", err
	}
	c, err := dial(addr)
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
	if len(s.output) != 2 || !strings.HasPrefix(s.output[1], "crash "+kind+" ") {
		return "", fmt.Errorf("output %q, want ready and one crash %s line", s.output, kind)
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
	if err := exchange(addr); err != nil {
		return "", fmt.Errorf("after the restart: %w", err)
	}
	summary, err := s2.account(newTrace(false), 1)
	return fmt.Sprintf("client saw %d response bytes, %q; restarted server: %s", len(got), s.output[1], summary), err
}

// rssKiB is the resident set size of process pid, from ps(1).
func rssKiB(pid int) (int, error) {
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(out)))
}

// memory measures the retained memory of connections holding a request
// head: 1000 connections each send an 8,000-byte head with
// `Expect: 100-continue` and a body still to come; the interim response is
// the event that shows the server buffered the head and waits. The growth
// of the resident set per connection must stay within the bound the README
// states per connection (perConnBound).
func memory(path, addr string) (string, error) {
	const n = 1000
	// README, "Memory": the loop's connection (two 8 KiB buffers and its
	// fields), the Lean buffer of at most inCap bytes, and a response of at
	// most 64 KiB, with 2 KiB for allocator and object headers.
	const perConnBound = (16640 + 16388 + 65536 + 2048) / 1024
	s, err := start(path, "1", "--max-conns", "1100")
	if err != nil {
		return "", err
	}
	defer s.stop()
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
	if per > perConnBound {
		return "", fmt.Errorf("%.1f KiB per connection, over the stated bound of %d KiB", per, perConnBound)
	}
	return fmt.Sprintf("resident set %d KiB idle, %d KiB with %d heads held: %.1f KiB per connection (bound %d KiB)", base, held, n, per, perConnBound), nil
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
	// custom, when set, replaces args and run: it starts its own servers and
	// returns a summary.
	custom func(path, addr string) (string, error)
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
	addr := flag.String("addr", "127.0.0.1:8083", "address the server listens on")
	noContinue := flag.Bool("no-continue", false, "the fixture does not answer Expect: 100-continue (lsrv-fixture-hand); skip the scenarios that need it")
	flag.Parse()
	scenarios := []scenario{
		{"large responses, operations of at most 7 bytes", []string{"2", "--chunk", "7", "--trace"}, false, false, exchanges(8), nil, false},
		{"large responses, full-size operations", []string{"2", "--trace"}, false, false, exchanges(16), nil, false},
		{"every 29th receive and every 29th send fail", []string{"2", "--fail-every", "29", "--trace"}, false, true, failures, nil, false},
		{"connection churn with resets", []string{"4", "--trace"}, true, false, churn, nil, false},
		{"Expect: 100-continue and a response over the bound, operations of at most 7 bytes", []string{"2", "--chunk", "7", "--trace"}, false, false, expectations, nil, true},
		{"graceful shutdown with a response in flight, an idle and a partial connection", nil, false, false, nil, shutdown, false},
		{"admission: at most 2 connections", nil, false, false, nil, admission, false},
		{"crash after the first receive", nil, false, false, nil, func(p, a string) (string, error) {
			return crashPoint(p, a, "--crash-after-recv", 1, 0)
		}, false},
		{"crash after the third 7-byte send", nil, false, false, nil, func(p, a string) (string, error) {
			return crashPoint(p, a, "--crash-after-send", 3, 21, "--chunk", "7")
		}, false},
		{"memory of 1000 connections holding a head", nil, false, false, nil, memory, true},
	}
	failed, ran := 0, 0
	for _, sc := range scenarios {
		if sc.continues && *noContinue {
			fmt.Printf("skipped %s: the fixture does not answer Expect: 100-continue\n", sc.name)
			continue
		}
		ran++
		if err := runScenario(*fixture, *addr, sc); err != nil {
			fmt.Printf("FAIL %s: %v\n", sc.name, err)
			failed++
		}
	}
	fmt.Printf("%d of %d boundary scenarios failed\n", failed, ran)
	if failed > 0 {
		os.Exit(1)
	}
}

func runScenario(path, addr string, sc scenario) error {
	if sc.custom != nil {
		summary, err := sc.custom(path, addr)
		if err == nil {
			fmt.Printf("ok %s: %s\n", sc.name, summary)
		}
		return err
	}
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
