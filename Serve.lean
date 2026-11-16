import Conn

/-! What the server executables share: the call that starts the zio.ev loops
(zig/src/serve.zig) and the command line. Each executable exports the loop's
entry points (`ekk_conn_open`, `ekk_conn_on_recv`, `ekk_conn_on_sent`,
`ekk_conn_on_fail`, called from zig/src/glue.c) for its own handler, through
the functions below. -/

namespace Serve

/-- A new connection: the initial state and its first action, a receive. -/
def connOpen : Conn.State × Conn.Action := (Conn.initial, .recv Conn.inCap)

def onRecv (handle : Nat → ByteArray → Reply) (now : UInt64) (s : Conn.State) (data : ByteArray) :
    Conn.State × Conn.Action :=
  Conn.step (handle now.toNat) s (.received data)

def onSent (handle : Nat → ByteArray → Reply) (now : UInt64) (s : Conn.State) (n : USize) :
    Conn.State × Conn.Action :=
  Conn.step (handle now.toNat) s (.sent n.toNat)

def onFail (handle : Nat → ByteArray → Reply) (s : Conn.State) : Conn.State × Conn.Action :=
  Conn.step (handle 0) s .failed

@[extern "ekk_serve"]
opaque serve (port : UInt16) (threads : UInt32) (chunk : USize) (failEvery : UInt32) (trace : UInt8) : UInt8

structure Options where
  threads : Nat := 8
  chunk : Nat := 0
  failEvery : Nat := 0
  trace : Bool := false

/-- `[THREADS] [--chunk N] [--fail-every N] [--trace]`; the last three are the
loop's test settings (`Testing` in zig/src/serve.zig). -/
def parseArgs : List String → Options → Except String Options
  | [], o => .ok o
  | "--chunk" :: n :: rest, o => match n.toNat? with
    | some k => parseArgs rest { o with chunk := k }
    | none => .error s!"--chunk: not a number: {n}"
  | "--fail-every" :: n :: rest, o => match n.toNat? with
    | some k => parseArgs rest { o with failEvery := k }
    | none => .error s!"--fail-every: not a number: {n}"
  | "--trace" :: rest, o => parseArgs rest { o with trace := true }
  | a :: rest, o => match a.toNat? with
    | some k => parseArgs rest { o with threads := k }
    | none => .error s!"unknown argument: {a}"

def main (args : List String) : IO UInt32 := do
  match parseArgs args {} with
  | .error e =>
    IO.eprintln e
    return 2
  | .ok o =>
    IO.println s!"serving on 127.0.0.1:8083 with {o.threads} loops"
    (← IO.getStdout).flush
    return (serve 8083 o.threads.toUInt32 o.chunk.toUSize o.failEvery.toUInt32 (if o.trace then 1 else 0)).toUInt32

end Serve
