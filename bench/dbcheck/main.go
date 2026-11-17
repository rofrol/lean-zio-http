// The PostgreSQL tests of the Lean server (lsrv-db, App.Db) against a private
// PostgreSQL cluster that bench.sh creates, which this program may stop and
// restart. Each test starts its own server and checks, without assumptions on
// elapsed time (a query is held by an advisory lock the test owns, and the
// test reads pg_stat_activity to know it is waiting):
//
//   - results: a primary-key SELECT, a missing row, two chained queries;
//   - slow query: while a query waits on one loop, that loop answers a request
//     with no query and, with a second pool slot, another query;
//   - pool exhaustion: one slot, a query waiting on it, more queries queue
//     (never more than one backend) and all complete once it is released;
//   - restart: `pg_ctl restart -m fast` with a query in flight answers it
//     503 (the lock it waits for is held by a prepared transaction, which
//     survives the restart, so the query cannot have finished first), and,
//     once the server's trace shows both old sessions closed, the requests
//     after the restart get 200 on fresh connections, on both slots;
//   - errors: on one slot, a query PostgreSQL cannot prepare, a cached
//     statement that fails when executed, and a query leaving a transaction
//     open each answer 500, and the slot then answers the next query;
//   - schema change: on one slot, a cached statement whose result type an
//     ALTER TABLE changed answers 500 with 0A000 once, then 200 on the same
//     backend, twice (the type changed and changed back), so preparing the
//     text again does not collide with the statements left on the server;
//   - oversized result: on one slot, an INSERT ... RETURNING within
//     Query.maxResultBytes answers its rows; one over it is abandoned
//     (Query.Result.abandoned) and answers 500 with 54000 and "outcome
//     unknown", the session is closed, the statement took effect wholly or
//     not at all (its outcome is unknown to the server), and the next query
//     answers 200 on a fresh session;
//   - database down: queries answer 503 while it is stopped, 200 once started;
//   - shutdown: SIGTERM with a query waiting lets it finish, then the server
//     exits with status 0 after printing "stopped";
//   - query deadline: a query whose budget ends while it waits on the lock
//     is abandoned (504, 57014, "outcome unknown"), its session is closed
//     without waiting for its backend, and the next query gets a fresh
//     session; one whose budget ends while it waits in the pool's queue
//     answers 504 with 57014 and no "outcome unknown", and the busy session
//     it waited behind serves on; a budget of 0 or over the ceiling answers
//     500 with 22023;
//   - statement_timeout: PostgreSQL ends a statement past --pg-statement-ms
//     itself (504, 57014, not abandoned) and the session serves on;
//   - connect deadline: against a listener that never answers, a connect
//     ends at --pg-connect-ms (503, 08006), and a query whose own budget
//     ends first answers 504 with 57014 while the connect runs on.
//
// The budgets under test are short, set by each test; the other tests set
// every database budget far beyond their run (`far`), since they hold
// queries on locks for as long as they need.
//
// Exhaustion, restart and shutdown read the server's trace (--trace) to know
// it has queued the queries, closed the old sessions or started its shutdown.
//
// HTTP requests have no deadline here: a hung request leaves the program
// quiet, which its runner reports. Exit status 1 on any failure.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/jackc/pgx/v5"
)

var (
	server   = flag.String("server", ".lake/build/bin/lsrv-db", "the lsrv-db executable")
	conninfo = flag.String("pg", "", "libpq conninfo of the private cluster")
	pgdata   = flag.String("pgdata", "", "the private cluster's data directory, for pg_ctl")
	pgopts   = flag.String("pgopts", "", "the options pg_ctl starts the cluster with (-o)")
	pglog    = flag.String("pglog", "", "the cluster's log file")
	// The running server's base URL, from its "listening on" line; the tests
	// run one server at a time.
	addr     = ""
	failures = 0
	ctx      = context.Background()
)

func fail(format string, args ...any) {
	failures++
	fmt.Printf("FAIL "+format+"\n", args...)
}

type srv struct {
	cmd   *exec.Cmd
	lines chan string
}

// The database budgets and the shutdown's drain of the tests that do not
// test them, beyond any run (delay: external deadline: the pool's database
// budgets and the drain, out of the way of tests that hold queries on locks).
var far = []string{"--pg-query-ms", "600000", "--pg-query-max-ms", "600000", "--pg-connect-ms", "600000",
	"--pg-statement-ms", "600000", "--drain-ms", "600000"}

// start runs lsrv-db with `args` and the private cluster's conninfo.
func start(args ...string) *srv {
	return startOn(*conninfo+" application_name=lsrv", append(append([]string{}, far...), args...)...)
}

// startOn runs lsrv-db with `args` against `pg` on a port the kernel picks,
// sets addr from its "listening on" line, and returns once it has printed
// "ready".
func startOn(pg string, args ...string) *srv {
	cmd := exec.Command(*server, append(args, "--port", "0", "--pg", pg)...)
	cmd.Stdout = io.Discard
	stderr, err := cmd.StderrPipe()
	if err != nil {
		panic(err)
	}
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	// Large enough for all its output, so the server never blocks on stderr.
	s := &srv{cmd: cmd, lines: make(chan string, 1<<16)}
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			s.lines <- sc.Text()
		}
		close(s.lines)
	}()
	var output []string
	addr = ""
	for line := range s.lines {
		output = append(output, line)
		if a, ok := strings.CutPrefix(line, "listening on "); ok {
			addr = "http://" + strings.Fields(a)[0]
		}
		if line == "ready" {
			if addr == "" {
				panic("lsrv-db printed ready without a listening on line: " + strings.Join(output, " | "))
			}
			return s
		}
	}
	panic("lsrv-db exited before it was ready: " + strings.Join(output, " | "))
}

// stop sends SIGTERM and requires "stopped" and exit status 0.
func (s *srv) stop(what string) {
	s.cmd.Process.Signal(syscall.SIGTERM)
	s.finish(what)
}

// await reads the server's output until `n` lines satisfy `match`.
func (s *srv) await(what string, n int, match func(string) bool) {
	for line := range s.lines {
		if match(line) {
			n--
			if n == 0 {
				return
			}
		}
	}
	fail("%s: the server exited before its trace showed it", what)
}

func (s *srv) finish(what string) {
	stopped := false
	for line := range s.lines {
		if line == "stopped" {
			stopped = true
		}
	}
	if err := s.cmd.Wait(); err != nil {
		fail("%s: the server exited with %v", what, err)
	}
	if !stopped {
		fail("%s: the server did not print stopped", what)
	}
}

type answer struct {
	status int
	body   string
	err    error
}

func get(path string) answer {
	r, err := http.Get(addr + path)
	if err != nil {
		return answer{err: err}
	}
	defer r.Body.Close()
	b, err := io.ReadAll(r.Body)
	return answer{r.StatusCode, string(b), err}
}

// getAsync runs get in its own goroutine (and so on its own connection while
// the others are busy).
func getAsync(path string) chan answer {
	ch := make(chan answer, 1)
	go func() { ch <- get(path) }()
	return ch
}

func expect(what string, a answer, status int, body string) {
	if a.err != nil || a.status != status || (body != "" && a.body != body) {
		fail("%s: got %d %q %v, want %d %q", what, a.status, a.body, a.err, status, body)
	}
}

// pending requires that `ch` has no answer yet.
func pending(what string, ch chan answer) {
	select {
	case a := <-ch:
		fail("%s: answered %d %q %v while its query should wait", what, a.status, a.body, a.err)
		ch <- a
	default:
	}
}

const world42 = `{"id":42,"randomNumber":2599}`

func connect() *pgx.Conn {
	c, err := pgx.Connect(ctx, *conninfo+" application_name=dbcheck")
	if err != nil {
		panic(err)
	}
	return c
}

func run(c *pgx.Conn, sql string, args ...any) {
	if _, err := c.Exec(ctx, sql, args...); err != nil {
		panic(fmt.Sprintf("%s: %v", sql, err))
	}
}

// lockHeld returns a connection holding the exclusive advisory lock `key`.
func lockHeld(key int) *pgx.Conn {
	c := connect()
	run(c, "SELECT pg_advisory_lock($1)", key)
	return c
}

// awaitWaiters returns once `n` of lsrv's backends wait for a lock. It reads
// pg_stat_activity: PostgreSQL, an external producer, sends no event for
// this. Bounded in reads.
func awaitWaiters(c *pgx.Conn, n int) bool {
	for i := 0; i < 100000; i++ {
		var k int
		if err := c.QueryRow(ctx,
			"SELECT count(*) FROM pg_stat_activity WHERE application_name = 'lsrv' AND wait_event_type = 'Lock'").Scan(&k); err != nil {
			panic(err)
		}
		if k == n {
			return true
		}
	}
	return false
}

func backends(c *pgx.Conn) int {
	var k int
	if err := c.QueryRow(ctx,
		"SELECT count(*) FROM pg_stat_activity WHERE application_name = 'lsrv'").Scan(&k); err != nil {
		panic(err)
	}
	return k
}

func pgctl(args ...string) {
	full := append([]string{"-D", *pgdata, "-w", "-l", *pglog}, args...)
	if args[0] != "stop" {
		full = append(full, "-o", *pgopts)
	}
	if out, err := exec.Command("pg_ctl", full...).CombinedOutput(); err != nil {
		panic(fmt.Sprintf("pg_ctl %v: %v\n%s", args, err, out))
	}
}

func testResults() {
	s := start("1", "--pg-conns", "2")
	expect("results: id 42", get("/db?id=42"), 200, world42)
	expect("results: no such row", get("/db?id=999999"), 404, "")
	expect("results: chained queries", get("/chain"), 200, "2")
	expect("results: no query", get("/"), 200, "Hello, World!")
	s.stop("results")
}

func testSlowQuery() {
	s := start("1", "--pg-conns", "2")
	l := lockHeld(7)
	slow := getAsync("/lock?key=7")
	if !awaitWaiters(l, 1) {
		fail("slow query: the query never waited for the lock")
	}
	expect("slow query: a request with no query on the same loop", get("/"), 200, "Hello, World!")
	expect("slow query: a query on the other slot", get("/db?id=42"), 200, world42)
	pending("slow query: the waiting query", slow)
	l.Close(ctx)
	expect("slow query: once released", <-slow, 200, "released")
	s.stop("slow query")
}

func testExhaustion() {
	s := start("1", "--pg-conns", "1", "--trace")
	l := lockHeld(8)
	slow := getAsync("/lock?key=8")
	if !awaitWaiters(l, 1) {
		fail("exhaustion: the query never waited for the lock")
	}
	var queued []chan answer
	for i := 0; i < 20; i++ {
		queued = append(queued, getAsync("/db?id=42"))
	}
	// The slow query's line and one per queued query: all are in the pool.
	s.await("exhaustion: queued", 21, func(l string) bool { return strings.HasPrefix(l, "query ") })
	expect("exhaustion: a request with no query", get("/"), 200, "Hello, World!")
	for i, ch := range queued {
		pending(fmt.Sprintf("exhaustion: queued query %d", i), ch)
	}
	if n := backends(l); n != 1 {
		fail("exhaustion: %d backends of lsrv, want 1 (the pool's size)", n)
	}
	l.Close(ctx)
	expect("exhaustion: the slow query", <-slow, 200, "released")
	for i, ch := range queued {
		expect(fmt.Sprintf("exhaustion: queued query %d", i), <-ch, 200, world42)
	}
	if n := backends(connect()); n != 1 {
		fail("exhaustion: %d backends of lsrv after the queue, want 1", n)
	}
	s.stop("exhaustion")
}

func testRestart() {
	s := start("1", "--pg-conns", "2", "--trace")
	// Open both slots' connections: a query waits on one while another runs.
	l := lockHeld(9)
	warm := getAsync("/lock?key=9")
	if !awaitWaiters(l, 1) {
		fail("restart: the warm-up query never waited for the lock")
	}
	expect("restart: warm-up", get("/db?id=42"), 200, world42)
	l.Close(ctx)
	expect("restart: warm-up", <-warm, 200, "released")
	// A prepared transaction holds the lock across the restart.
	h := connect()
	run(h, "BEGIN")
	run(h, "SELECT pg_advisory_xact_lock(9)")
	run(h, "PREPARE TRANSACTION 'dbcheck'")
	inflight := getAsync("/lock?key=9")
	if !awaitWaiters(h, 1) {
		fail("restart: the query never waited for the lock")
	}
	h.Close(ctx)
	pgctl("restart", "-m", "fast")
	// It was sent: the lost connection leaves its outcome unknown.
	expect("restart: the query in flight", <-inflight, 503, "database error 08006, outcome unknown\n")
	// The idle slot ends its session when the loop handles its EOF, which
	// may come after the next request (best effort, README): wait for both.
	s.await("restart: old sessions closed", 2, func(l string) bool { return l == "pg closed" })
	h = connect()
	run(h, "COMMIT PREPARED 'dbcheck'")
	for i := 0; i < 4; i++ {
		expect("restart: after the restart", get("/db?id=42"), 200, world42)
	}
	// Both slots again: one waits, the other answers.
	l = lockHeld(9)
	warm = getAsync("/lock?key=9")
	if !awaitWaiters(l, 1) {
		fail("restart: the query after the restart never waited for the lock")
	}
	expect("restart: the second slot after the restart", get("/db?id=42"), 200, world42)
	l.Close(ctx)
	expect("restart: the first slot after the restart", <-warm, 200, "released")
	h.Close(ctx)
	s.stop("restart")
}

func testErrors() {
	s := start("1", "--pg-conns", "1")
	expect("errors: a query that cannot be prepared", get("/bad"), 500, "database error 42703\n")
	expect("errors: the next query", get("/db?id=42"), 200, world42)
	expect("errors: a statement prepared", get("/div?d=1"), 200, "1")
	expect("errors: the cached statement failing", get("/div?d=0"), 500, "database error 22012\n")
	expect("errors: the cached statement again", get("/div?d=2"), 200, "0")
	expect("errors: a transaction left open", get("/begin"), 500, "database error 25000\n")
	expect("errors: after the transaction", get("/db?id=42"), 200, world42)
	s.stop("errors")
}

// backendPid returns the pid of lsrv's one backend.
func backendPid(c *pgx.Conn) int {
	var pid int
	if err := c.QueryRow(ctx,
		"SELECT pid FROM pg_stat_activity WHERE application_name = 'lsrv'").Scan(&pid); err != nil {
		panic(err)
	}
	return pid
}

func testSchemaChange() {
	s := start("1", "--pg-conns", "1")
	c := connect()
	expect("schema change: the statement prepared", get("/db?id=42"), 200, world42)
	pid := backendPid(c)
	for _, typ := range []string{"bigint", "int"} {
		run(c, "ALTER TABLE world ALTER COLUMN randomnumber TYPE "+typ)
		expect("schema change to "+typ+": the cached statement", get("/db?id=42"), 500, "database error 0A000\n")
		expect("schema change to "+typ+": prepared again", get("/db?id=42"), 200, world42)
		if p := backendPid(c); p != pid {
			fail("schema change to %s: backend %d, want the same session's %d", typ, p, pid)
		}
	}
	c.Close(ctx)
	s.stop("schema change")
}

// awaitNoBackends returns once lsrv has no backend left. It reads
// pg_stat_activity: PostgreSQL, an external producer, sends no event for
// this. Bounded in reads.
func awaitNoBackends(c *pgx.Conn) bool {
	for i := 0; i < 100000; i++ {
		if backends(c) == 0 {
			return true
		}
	}
	return false
}

func count(c *pgx.Conn, sql string) int {
	var k int
	if err := c.QueryRow(ctx, sql).Scan(&k); err != nil {
		panic(err)
	}
	return k
}

func testOversized() {
	c := connect()
	run(c, "DROP TABLE IF EXISTS big")
	run(c, "CREATE TABLE big (v text)")
	s := start("1", "--pg-conns", "1", "--trace")
	expect("oversized: within the bound", get("/insert?n=10"), 200, "10")
	expect("oversized: over the bound", get("/insert?n=2000"), 500, "database error 54000, outcome unknown\n")
	s.await("oversized: the session closed", 1, func(l string) bool { return l == "pg closed" })
	// The server ends the statement's backend (an error writing to the
	// closed connection) or it finishes first; either way it is atomic.
	if !awaitNoBackends(c) {
		fail("oversized: the closed session's backend never ended")
	}
	if n := count(c, "SELECT count(*) FROM big"); n != 10 && n != 2010 {
		fail("oversized: %d rows in big, want 10 (rolled back) or 2010 (committed)", n)
	}
	expect("oversized: the next query", get("/db?id=42"), 200, world42)
	run(c, "DROP TABLE big")
	c.Close(ctx)
	s.stop("oversized")
}

func testDown() {
	s := start("1", "--pg-conns", "2")
	expect("down: before", get("/db?id=42"), 200, world42)
	pgctl("stop", "-m", "fast")
	for i := 0; i < 3; i++ {
		expect("down: while stopped", get("/db?id=42"), 503, "")
	}
	expect("down: no query while stopped", get("/"), 200, "Hello, World!")
	pgctl("start")
	expect("down: after the start", get("/db?id=42"), 200, world42)
	s.stop("down")
}

func testShutdown() {
	s := start("1", "--pg-conns", "1", "--trace")
	l := lockHeld(11)
	waiting := getAsync("/lock?key=11")
	if !awaitWaiters(l, 1) {
		fail("shutdown: the query never waited for the lock")
	}
	s.cmd.Process.Signal(syscall.SIGTERM)
	s.await("shutdown: started", 1, func(l string) bool { return strings.HasPrefix(l, "stop ") })
	// The server keeps the query: it answers once the lock is released.
	pending("shutdown: the waiting query", waiting)
	l.Close(ctx)
	expect("shutdown: the waiting query", <-waiting, 200, "released")
	s.finish("shutdown")
}

// The budgets under test below (delay: external deadline: a query's or a
// connect's budget, or PostgreSQL's statement_timeout, the test waits for
// it to end).
const short = "300"

func testQueryDeadline() {
	s := start("1", "--pg-conns", "1", "--trace", "--pg-query-max-ms", "600000")
	c := connect()
	expect("query deadline: a session opened", get("/db?id=42"), 200, world42)
	pid := backendPid(c)
	// Expiry in flight: the query waits on the lock past its budget.
	l := lockHeld(12)
	expect("query deadline: in flight", get("/lock?key=12&ms="+short), 504, "database error 57014, outcome unknown\n")
	s.await("query deadline: the session closed", 1, func(l string) bool { return l == "pg closed" })
	// No cancel was sent: the backend still waits on the lock until it is
	// released, and ends when its answer finds the connection closed.
	if !awaitWaiters(c, 1) {
		fail("query deadline: the closed session's backend no longer waits")
	}
	l.Close(ctx)
	if !awaitNoBackends(c) {
		fail("query deadline: the closed session's backend never ended")
	}
	expect("query deadline: the next query", get("/db?id=42"), 200, world42)
	if p := backendPid(c); p == pid {
		fail("query deadline: backend %d serves again after its session expired", p)
	}
	pid = backendPid(c)

	// Expiry in the queue: one slot, busy with a query waiting on a lock.
	l = lockHeld(13)
	busy := getAsync("/lock?key=13")
	if !awaitWaiters(c, 1) {
		fail("query deadline: the busy query never waited for the lock")
	}
	expect("query deadline: in the queue", get("/lock?key=14&ms="+short), 504, "database error 57014\n")
	pending("query deadline: the busy query", busy)
	l.Close(ctx)
	expect("query deadline: the busy query", <-busy, 200, "released")
	expect("query deadline: after the queue", get("/db?id=42"), 200, world42)
	if p := backendPid(c); p != pid {
		fail("query deadline: backend %d, want the busy session's %d", p, pid)
	}

	expect("query deadline: a budget of 0", get("/lock?key=15&ms=0"), 500, "database error 22023\n")
	expect("query deadline: a budget over the ceiling", get("/lock?key=15&ms=600001"), 500, "database error 22023\n")
	c.Close(ctx)
	s.stop("query deadline")
}

func testStatementTimeout() {
	s := start("1", "--pg-conns", "1", "--pg-statement-ms", short)
	c := connect()
	expect("statement_timeout: a session opened", get("/db?id=42"), 200, world42)
	pid := backendPid(c)
	l := lockHeld(16)
	expect("statement_timeout: the statement ended by PostgreSQL", get("/lock?key=16"), 504, "database error 57014\n")
	l.Close(ctx)
	expect("statement_timeout: the next query", get("/db?id=42"), 200, world42)
	if p := backendPid(c); p != pid {
		fail("statement_timeout: backend %d, want the same session's %d", p, pid)
	}
	c.Close(ctx)
	s.stop("statement_timeout")
}

func testConnectDeadline() {
	// A listener that accepts no connection: the kernel completes the
	// handshake, libpq sends its startup packet, and no answer comes.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	pg := fmt.Sprintf("hostaddr=127.0.0.1 port=%d sslmode=disable gssencmode=disable dbname=x user=x", ln.Addr().(*net.TCPAddr).Port)
	s := startOn(pg, "1", "--pg-conns", "1", "--pg-connect-ms", short)
	expect("connect deadline: the connect ends", get("/db?id=42"), 503, "database error 08006\n")
	s.stop("connect deadline")

	// The default connect budget (5 s) outlasts the query's.
	s = startOn(pg, "1", "--pg-conns", "1")
	expect("connect deadline: the query's own budget first", get("/lock?key=1&ms="+short), 504, "database error 57014\n")
	// The connect still runs: closing the listener resets it, so the
	// shutdown need not wait for its budget.
	ln.Close()
	s.stop("connect deadline")
}

// The shutdown's drain ends with one query running on a lock and one queued
// behind it: both connections close without an answer, the running query's
// session is closed without a cancel (its backend waits on until the lock is
// released), and the server exits.
func testDrain() {
	s := start("1", "--pg-conns", "1", "--trace", "--drain-ms", short)
	c := connect()
	l := lockHeld(17)
	running := getAsync("/lock?key=17")
	if !awaitWaiters(c, 1) {
		fail("drain: the running query never waited for the lock")
	}
	queued := getAsync("/lock?key=18")
	s.await("drain: queued", 2, func(l string) bool { return strings.HasPrefix(l, "query ") })
	s.cmd.Process.Signal(syscall.SIGTERM)
	s.await("drain: ended", 1, func(l string) bool { return l == "drain ended" })
	for _, q := range []struct {
		what string
		ch   chan answer
	}{{"running", running}, {"queued", queued}} {
		if a := <-q.ch; a.err == nil {
			fail("drain: the %s query was answered %d %q; want its connection closed", q.what, a.status, a.body)
		}
	}
	s.finish("drain")
	if !awaitWaiters(c, 1) {
		fail("drain: the closed session's backend no longer waits")
	}
	l.Close(ctx)
	if !awaitNoBackends(c) {
		fail("drain: the closed session's backend never ended")
	}
	c.Close(ctx)
}

func main() {
	flag.Parse()
	if *conninfo == "" || *pgdata == "" || *pglog == "" {
		fmt.Println("usage: dbcheck -pg CONNINFO -pgdata DIR -pgopts OPTS -pglog FILE [-server PATH]")
		os.Exit(2)
	}
	for _, t := range []struct {
		name string
		run  func()
	}{
		{"results", testResults}, {"slow query", testSlowQuery}, {"exhaustion", testExhaustion},
		{"restart", testRestart}, {"errors", testErrors},
		{"schema change", testSchemaChange}, {"oversized", testOversized}, {"down", testDown}, {"shutdown", testShutdown},
		{"query deadline", testQueryDeadline}, {"statement_timeout", testStatementTimeout},
		{"connect deadline", testConnectDeadline}, {"drain", testDrain},
	} {
		before := failures
		t.run()
		fmt.Printf("dbcheck %s: %s\n", t.name, map[bool]string{true: "ok", false: "FAILED"}[failures == before])
	}
	if failures > 0 {
		fmt.Printf("dbcheck: %d failures\n", failures)
		os.Exit(1)
	}
	fmt.Println("dbcheck: 0 failures")
}
