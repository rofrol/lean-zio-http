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

/-- A protocol adapter as the transport drives it: the wall clock in Unix
seconds, then the bytes buffered on a connection. -/
abbrev Adapter := Nat → ByteArray → Reply

/-- A new connection: the initial state and its first action, a receive. -/
def connOpen : Conn.State × Conn.Action := (Conn.initial, .recv inCap)

def onRecv (adapter : Adapter) (now : UInt64) (s : Conn.State) (data : ByteArray) : Conn.State × Conn.Action :=
  Conn.step (adapter now.toNat) s (.received data)

def onSent (adapter : Adapter) (now : UInt64) (s : Conn.State) (n : USize) : Conn.State × Conn.Action :=
  Conn.step (adapter now.toNat) s (.sent n.toNat)

def onFail (adapter : Adapter) (s : Conn.State) : Conn.State × Conn.Action :=
  Conn.step (adapter 0) s .failed

def onRefused (adapter : Adapter) (s : Conn.State) : Conn.State × Conn.Action :=
  Conn.step (adapter 0) s .refused

def onAnswer (adapter : Adapter) (now : UInt64) (s : Conn.State) (r : Query.Result) : Conn.State × Conn.Action :=
  Conn.step (adapter now.toNat) s (.answered r)

set_option hygiene false in
/-- Writes the loop's entry points for `adapter` in the executable that uses
it: `server_exports (Server.H1Adapter.handle {} App.Hello.app)`. Unhygienic, so
the export names reach the C symbol table as written. -/
macro "server_exports " adapter:term : command => `(
  @[export ekk_conn_open] def connOpen (_ : UInt8) : Server.Conn.State × Server.Conn.Action :=
    Server.Transport.connOpen
  @[export ekk_conn_on_recv] def onRecv (now : UInt64) (s : Server.Conn.State) (data : ByteArray) :
      Server.Conn.State × Server.Conn.Action := Server.Transport.onRecv $adapter now s data
  @[export ekk_conn_on_sent] def onSent (now : UInt64) (s : Server.Conn.State) (n : USize) :
      Server.Conn.State × Server.Conn.Action := Server.Transport.onSent $adapter now s n
  @[export ekk_conn_on_fail] def onFail (s : Server.Conn.State) : Server.Conn.State × Server.Conn.Action :=
    Server.Transport.onFail $adapter s
  @[export ekk_conn_on_refused] def onRefused (s : Server.Conn.State) : Server.Conn.State × Server.Conn.Action :=
    Server.Transport.onRefused $adapter s
  @[export ekk_conn_on_answer] def onAnswer (now : UInt64) (s : Server.Conn.State) (r : Server.Query.Result) :
      Server.Conn.State × Server.Conn.Action := Server.Transport.onAnswer $adapter now s r)

/-- The loop's settings, passed to `ekk_serve` (zig/src/serve.zig). -/
structure Options where
  threads : Nat := 8
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

/-- `[THREADS] [--max-conns N] [--pg CONNINFO] [--pg-conns N] [--chunk N]
[--fail-every N] [--trace] [--crash-after-recv N] [--crash-after-send N]`;
the last five are the loop's test settings. Serves on 127.0.0.1:8083 until SIGTERM or SIGINT, then
shuts down gracefully and returns 0 (README, "Production contract"). -/
def main (args : List String) : IO UInt32 := do
  match parseArgs args {} with
  | .error e =>
    IO.eprintln e
    return 2
  | .ok o =>
    if o.threads == 0 || o.maxConns == 0 || o.maxConns ≥ 2 ^ 31 then
      IO.eprintln "THREADS and --max-conns must be at least 1"
      return 2
    if o.pgConns ≥ 2 ^ 16 || o.pg.contains (Char.ofNat 0) then
      IO.eprintln "--pg-conns must be below 65536 and --pg must hold no NUL"
      return 2
    let pgConns := if o.pg.isEmpty then 0 else o.pgConns
    IO.println s!"serving on 127.0.0.1:8083 with {o.threads} loops, at most {o.maxConns} connections"
    (← IO.getStdout).flush
    return (serve 8083 o.threads.toUInt32 o.maxConns.toUInt32 o.pg pgConns.toUInt32 o.chunk.toUSize o.failEvery.toUInt32
      (if o.trace then 1 else 0) o.crashAfterRecv.toUInt32 o.crashAfterSend.toUInt32).toUInt32

end Server.Transport
