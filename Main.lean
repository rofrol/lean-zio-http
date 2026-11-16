import Http

/-! Spike entry point: starts the zio.ev loops (zig/src/serve.zig), which call `Http.handle`. -/

@[extern "ekk_serve"]
opaque serve (port : UInt16) (threads : UInt32) : UInt8

def main (args : List String) : IO UInt32 := do
  let threads := (args.head? >>= String.toNat?).getD 8
  IO.println s!"serving on 127.0.0.1:8083 with {threads} loops"
  (← IO.getStdout).flush
  return (serve 8083 threads.toUInt32).toUInt32
