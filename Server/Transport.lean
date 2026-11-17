import Server.Wire
import Server.Conn

/-! The transport's Lean side: the call that starts the zio.ev loops
(zig/src/serve.zig, through zig/src/glue.c) and the command line. A server
executable (the composition root: `Main.lean`, `Fixture.lean` and their
hand-written-parser twins) picks a protocol adapter and an application and
exports the loop's entry points (`ekk_conn_open`, `ekk_conn_on_recv`,
`ekk_conn_on_sent`, `ekk_conn_on_fail`, `ekk_conn_on_refused`,
`ekk_conn_on_answer`, `ekk_conn_on_expired`, `ekk_conn_on_arrived`, the
deadline a state runs under, `ekk_conn_deadline` and `ekk_conn_gen`, the head
budget beside a send, `ekk_conn_ahead` and `ekk_conn_ahead_gen`, and whether
the loop watches for a next request, `ekk_conn_watch`) through the functions below;
the command `server_exports` writes them. -/

namespace Server.Transport

variable {σ : Type}

/-! The transport drives one adapter value for all of a connection's events
and passes each event's wall clock (Unix seconds, from the loop) to
`Conn.step`, which hands it only to the response it sends (`Server.Dated`);
so `Conn`'s theorems, stated for one adapter at any clock, describe the
transport. A failure, a declined receive, an expiry and an arrival send
nothing, so those events pass 0. -/

/-- The connection state of `adapter`'s connections, for the exports' types. -/
abbrev ConnState {σ : Type} (_ : Server.Adapter σ) : Type := Conn.State σ

/-- A new connection: the initial state and its first action, a receive. -/
def connOpen (adapter : Server.Adapter σ) : Conn.State σ × Conn.Action := (Conn.initial adapter, .recv inCap)

def onRecv (adapter : Server.Adapter σ) (now : UInt64) (s : Conn.State σ) (data : ByteArray) : Conn.State σ × Conn.Action :=
  Conn.step adapter now.toNat s (.received data)

def onSent (adapter : Server.Adapter σ) (now : UInt64) (s : Conn.State σ) (n : USize) : Conn.State σ × Conn.Action :=
  Conn.step adapter now.toNat s (.sent n.toNat)

def onFail (adapter : Server.Adapter σ) (s : Conn.State σ) : Conn.State σ × Conn.Action :=
  Conn.step adapter 0 s .failed

def onRefused (adapter : Server.Adapter σ) (s : Conn.State σ) : Conn.State σ × Conn.Action :=
  Conn.step adapter 0 s .refused

def onAnswer (adapter : Server.Adapter σ) (now : UInt64) (s : Conn.State σ) (r : Query.Result) : Conn.State σ × Conn.Action :=
  Conn.step adapter now.toNat s (.answered r)

def onArrived (adapter : Server.Adapter σ) (s : Conn.State σ) : Conn.State σ × Conn.Action :=
  Conn.step adapter 0 s .arrived

/-- A deadline as the loop names it: 1 idle, 2 head, 3 body, 4 write. -/
def deadlineCode : Conn.Deadline → UInt8
  | .idle => 1
  | .head => 2
  | .body => 3
  | .write => 4

def deadlineOfCode : UInt8 → Option Conn.Deadline
  | 1 => some .idle
  | 2 => some .head
  | 3 => some .body
  | 4 => some .write
  | _ => none

theorem deadlineOfCode_code (d : Conn.Deadline) : deadlineOfCode (deadlineCode d) = some d := by
  cases d <;> rfl

/-- The deadline `s` runs under, as the loop names it, 0 for none. -/
def stateDeadline (s : Conn.State σ) : UInt8 := match s.phase.deadline with
  | some d => deadlineCode d
  | none => 0

/-- The head budget running beside a send (`Conn.Phase.ahead`), as the loop
names it, 0 for none; its generation is `aheadGen`. -/
def stateAhead (s : Conn.State σ) : UInt8 := match s.phase.ahead with
  | some d => deadlineCode d
  | none => 0

def aheadGen (s : Conn.State σ) : Nat := s.gen + 1

/-- The timer the loop armed for deadline `kind` (as `stateDeadline` named it)
in generation `gen` ended. The loop passes back only a pair it was given, so
an unknown code does not occur; it is answered as a stale expiry is. -/
def onExpired (adapter : Server.Adapter σ) (s : Conn.State σ) (kind : UInt8) (gen : Nat) : Conn.State σ × Conn.Action :=
  match deadlineOfCode kind with
  | some d => Conn.step adapter 0 s (.expired d gen)
  | none => (s, .none)

set_option hygiene false in
/-- Writes the loop's entry points for `adapter` in the executable that uses
it: `server_exports (Server.H1Adapter.adapter {} App.Hello.app)`. Unhygienic, so
the export names reach the C symbol table as written. The loop holds the
connection state as an opaque object, whatever the adapter's state type. -/
macro "server_exports " adapter:term : command => `(
  @[export ekk_conn_open] def connOpen (_ : UInt8) : Server.Transport.ConnState $adapter × Server.Conn.Action :=
    Server.Transport.connOpen $adapter
  @[export ekk_conn_on_recv] def onRecv (now : UInt64) (s : Server.Transport.ConnState $adapter) (data : ByteArray) :
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onRecv $adapter now s data
  @[export ekk_conn_on_sent] def onSent (now : UInt64) (s : Server.Transport.ConnState $adapter) (n : USize) :
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onSent $adapter now s n
  @[export ekk_conn_on_fail] def onFail (s : Server.Transport.ConnState $adapter) :
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onFail $adapter s
  @[export ekk_conn_on_refused] def onRefused (s : Server.Transport.ConnState $adapter) :
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onRefused $adapter s
  @[export ekk_conn_on_answer] def onAnswer (now : UInt64) (s : Server.Transport.ConnState $adapter) (r : Server.Query.Result) :
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onAnswer $adapter now s r
  @[export ekk_conn_on_expired] def onExpired (s : Server.Transport.ConnState $adapter) (kind : UInt8) (gen : Nat) :
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onExpired $adapter s kind gen
  @[export ekk_conn_deadline] def deadline (s : Server.Transport.ConnState $adapter) : UInt8 :=
    Server.Transport.stateDeadline s
  @[export ekk_conn_gen] def gen (s : Server.Transport.ConnState $adapter) : Nat := s.gen
  @[export ekk_conn_on_arrived] def onArrived (s : Server.Transport.ConnState $adapter) :
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onArrived $adapter s
  @[export ekk_conn_ahead] def ahead (s : Server.Transport.ConnState $adapter) : UInt8 :=
    Server.Transport.stateAhead s
  @[export ekk_conn_ahead_gen] def aheadGen (s : Server.Transport.ConnState $adapter) : Nat :=
    Server.Transport.aheadGen s
  @[export ekk_conn_watch] def watch (s : Server.Transport.ConnState $adapter) : UInt8 :=
    if s.watches then 1 else 0)

/-- The loop's settings, passed to `ekk_serve` (zig/src/serve.zig). -/
structure Options where
  threads : Nat := 8
  /-- The port on 127.0.0.1; 0 asks the kernel for a free one, which the
  `listening on` line reports (the checks use that). -/
  port : Nat := 8083
  /-- Most connections open at once, process-wide; more wait in the kernel's
  listen queue. -/
  maxConns : Nat := 4096
  /-- The PostgreSQL connection string (libpq's conninfo); it must name a
  Unix socket directory (`host=/path`) or an address (`hostaddr=`), since
  resolving a host name would block a loop. -/
  pg : String := ""
  /-- Most PostgreSQL connections per loop; without `pg` there are none, and
  every query is answered with an error. -/
  pgConns : Nat := 4
  /-- The per-connection deadlines in milliseconds (`Server.Conn.Deadline`),
  each a budget the peer gets (an external deadline, policy rule 10), each at
  least 1. Calibrated on nginx (60 s `client_header_timeout`,
  `client_body_timeout` and `send_timeout`, 75 s `keepalive_timeout`) and on
  H2O's 10 s header budget (decided 2026-11-17, item ytzycm). Keep-alive
  idle: 60 s from the end of a response to the next request's first byte. -/
  idleMs : Nat := 60000
  /-- A request's head: 10 s, from accept for the first request and from its
  first byte for a later one, also while the response before it is sent
  (`Conn.Phase.ahead`); bytes do not extend it. -/
  headMs : Nat := 10000
  /-- A request's body: 30 s from the acceptance of its head. -/
  bodyMs : Nat := 30000
  /-- A response: 30 s from when it is ready to its last byte handed to the
  socket. -/
  writeMs : Nat := 30000
  /-- The PostgreSQL pool's deadlines in milliseconds (README, "PostgreSQL",
  "Deadlines"), each an external database budget (policy rule 10), each at
  least 1 (decided 2026-11-17, item 3jnkx5). A query's completion budget when
  it names none (`Server.Query.timeoutMs`): 5 s from its submission to the
  pool to its complete result, queueing included. -/
  pgQueryMs : Nat := 5000
  /-- The largest `Server.Query.timeoutMs` a query may name: 5 s. -/
  pgQueryMaxMs : Nat := 5000
  /-- A connect: 5 s from its start to a connection ready for queries. -/
  pgConnectMs : Nat := 5000
  /-- PostgreSQL's own `statement_timeout`, set in every session's startup
  options: 4 s, below the query budget, so the server usually ends a long
  statement itself and the session survives. -/
  pgStatementMs : Nat := 4000
  /-- The shutdown's drain in milliseconds, at least 1: 10 s from a loop's stop
  to the forced close of what is still open there (queries answered, their
  sessions closed, sends canceled). The overall shutdown bound the owner set
  (decided 2026-11-17, item ytzycm; built by item 3jnkx5), an external
  deadline for the supervisor that stops the server (policy rule 10). -/
  drainMs : Nat := 10000
  /-- Test settings (`Testing` in zig/src/serve.zig); all zero in normal runs. -/
  chunk : Nat := 0
  failEvery : Nat := 0
  trace : Bool := false
  crashAfterRecv : Nat := 0
  crashAfterSend : Nat := 0

@[extern "ekk_serve"]
opaque serve (port : UInt16) (threads : UInt32) (maxConns : UInt32) (pg : @& String) (pgConns : UInt32)
  (idleMs headMs bodyMs writeMs : UInt32) (pgQueryMs pgQueryMaxMs pgConnectMs pgStatementMs : UInt32) (drainMs : UInt32) (chunk : USize) (failEvery : UInt32) (trace : UInt8) (crashAfterRecv : UInt32) (crashAfterSend : UInt32) : UInt8

def parseArgs : List String → Options → Except String Options
  | [], o => .ok o
  | flag :: n :: rest, o =>
    let num := n.toNat?
    match flag, num with
    | "--pg", _ => parseArgs rest { o with pg := n }
    | "--port", some k => parseArgs rest { o with port := k }
    | "--pg-conns", some k => parseArgs rest { o with pgConns := k }
    | "--max-conns", some k => parseArgs rest { o with maxConns := k }
    | "--idle-ms", some k => parseArgs rest { o with idleMs := k }
    | "--head-ms", some k => parseArgs rest { o with headMs := k }
    | "--body-ms", some k => parseArgs rest { o with bodyMs := k }
    | "--write-ms", some k => parseArgs rest { o with writeMs := k }
    | "--pg-query-ms", some k => parseArgs rest { o with pgQueryMs := k }
    | "--pg-query-max-ms", some k => parseArgs rest { o with pgQueryMaxMs := k }
    | "--pg-connect-ms", some k => parseArgs rest { o with pgConnectMs := k }
    | "--pg-statement-ms", some k => parseArgs rest { o with pgStatementMs := k }
    | "--drain-ms", some k => parseArgs rest { o with drainMs := k }
    | "--chunk", some k => parseArgs rest { o with chunk := k }
    | "--fail-every", some k => parseArgs rest { o with failEvery := k }
    | "--crash-after-recv", some k => parseArgs rest { o with crashAfterRecv := k }
    | "--crash-after-send", some k => parseArgs rest { o with crashAfterSend := k }
    | "--trace", _ => parseArgs (n :: rest) { o with trace := true }
    | _, _ => match flag.toNat? with
      | some k => parseArgs (n :: rest) { o with threads := k }
      | none => .error s!"unknown argument or not a number: {flag} {n}"
  | ["--trace"], o => .ok { o with trace := true }
  | [a], o => match a.toNat? with
    | some k => .ok { o with threads := k }
    | none => .error s!"unknown argument: {a}"

/-- `[THREADS] [--port N] [--max-conns N] [--pg CONNINFO] [--pg-conns N]
[--idle-ms N] [--head-ms N] [--body-ms N] [--write-ms N] [--pg-query-ms N]
[--pg-query-max-ms N] [--pg-connect-ms N] [--pg-statement-ms N] [--drain-ms N] [--chunk N]
[--fail-every N] [--trace] [--crash-after-recv N] [--crash-after-send N]`;
the last five are the loop's test settings. Serves on 127.0.0.1:PORT (default
8083) until SIGTERM or SIGINT, then shuts down gracefully and returns 0
(README, "Production contract"). Once listening it prints `listening on
127.0.0.1:PORT ...` to stderr; when the port cannot be had it prints why,
with the errno, and returns 1. -/
def main (args : List String) : IO UInt32 := do
  match parseArgs args {} with
  | .error e =>
    IO.eprintln e
    return 2
  | .ok o =>
    if o.threads == 0 || o.maxConns == 0 || o.maxConns ≥ 2 ^ 31 then
      IO.eprintln "THREADS and --max-conns must be at least 1"
      return 2
    if o.port ≥ 2 ^ 16 then
      IO.eprintln "--port must be below 65536"
      return 2
    if o.pgConns ≥ 2 ^ 16 || o.pg.contains (Char.ofNat 0) then
      IO.eprintln "--pg-conns must be below 65536 and --pg must hold no NUL"
      return 2
    if [o.idleMs, o.headMs, o.bodyMs, o.writeMs, o.drainMs].any (fun ms => ms == 0 || ms ≥ 2 ^ 32) then
      IO.eprintln "--idle-ms, --head-ms, --body-ms, --write-ms and --drain-ms must be at least 1 and below 4294967296"
      return 2
    if [o.pgQueryMs, o.pgQueryMaxMs, o.pgConnectMs, o.pgStatementMs].any (fun ms => ms == 0 || ms ≥ 2 ^ 31)
        || o.pgQueryMaxMs < o.pgQueryMs then
      IO.eprintln "--pg-query-ms, --pg-query-max-ms, --pg-connect-ms and --pg-statement-ms must be at least 1 and below 2147483648, and --pg-query-max-ms at least --pg-query-ms"
      return 2
    let pgConns := if o.pg.isEmpty then 0 else o.pgConns
    return (serve o.port.toUInt16 o.threads.toUInt32 o.maxConns.toUInt32 o.pg pgConns.toUInt32
      o.idleMs.toUInt32 o.headMs.toUInt32 o.bodyMs.toUInt32 o.writeMs.toUInt32
      o.pgQueryMs.toUInt32 o.pgQueryMaxMs.toUInt32 o.pgConnectMs.toUInt32 o.pgStatementMs.toUInt32 o.drainMs.toUInt32 o.chunk.toUSize o.failEvery.toUInt32
      (if o.trace then 1 else 0) o.crashAfterRecv.toUInt32 o.crashAfterSend.toUInt32).toUInt32

end Server.Transport
