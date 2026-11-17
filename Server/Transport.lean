import Server.Wire
import Server.Conn

/-! The transport's Lean side: the call that starts the zio.ev loops
(zig/src/serve.zig, through zig/src/glue.c) and the command line. A server
executable (the composition root: `Main.lean`, `Fixture.lean` and their
hand-written-parser twins) picks a protocol adapter and an application and
exports the loop's entry points (`ekk_conn_open`, `ekk_conn_on_recv`,
`ekk_conn_on_sent`, `ekk_conn_on_fail`, `ekk_conn_on_refused`,
`ekk_conn_on_answer`) through the functions below; the command `server_exports` writes them. -/

namespace Server.Transport

variable {σ : Type}

/-! The transport drives one adapter value for all of a connection's events
and passes each event's wall clock (Unix seconds, from the loop) to
`Conn.step`, which hands it only to the response it sends (`Server.Dated`);
so `Conn`'s theorems, stated for one adapter at any clock, describe the
transport. A failure or a declined receive sends nothing, so those events
pass 0. -/

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
      Server.Transport.ConnState $adapter × Server.Conn.Action := Server.Transport.onAnswer $adapter now s r)

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
  /-- Test settings (`Testing` in zig/src/serve.zig); all zero in normal runs. -/
  chunk : Nat := 0
  failEvery : Nat := 0
  trace : Bool := false
  crashAfterRecv : Nat := 0
  crashAfterSend : Nat := 0

@[extern "ekk_serve"]
opaque serve (port : UInt16) (threads : UInt32) (maxConns : UInt32) (pg : @& String) (pgConns : UInt32)
  (chunk : USize) (failEvery : UInt32) (trace : UInt8) (crashAfterRecv : UInt32) (crashAfterSend : UInt32) : UInt8

def parseArgs : List String → Options → Except String Options
  | [], o => .ok o
  | flag :: n :: rest, o =>
    let num := n.toNat?
    match flag, num with
    | "--pg", _ => parseArgs rest { o with pg := n }
    | "--port", some k => parseArgs rest { o with port := k }
    | "--pg-conns", some k => parseArgs rest { o with pgConns := k }
    | "--max-conns", some k => parseArgs rest { o with maxConns := k }
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

/-- `[THREADS] [--port N] [--max-conns N] [--pg CONNINFO] [--pg-conns N] [--chunk N]
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
    let pgConns := if o.pg.isEmpty then 0 else o.pgConns
    return (serve o.port.toUInt16 o.threads.toUInt32 o.maxConns.toUInt32 o.pg pgConns.toUInt32 o.chunk.toUSize o.failEvery.toUInt32
      (if o.trace then 1 else 0) o.crashAfterRecv.toUInt32 o.crashAfterSend.toUInt32).toUInt32

end Server.Transport
