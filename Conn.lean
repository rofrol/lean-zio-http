import Http

/-! The lifecycle of one connection, owned by Lean.

The zio.ev loop (Zig) keeps no buffer or protocol state of its own: it reports
the outcome of the operation it last performed as an `Event`, and performs the
`Action` that `step` returns. `step` is pure and generic over the request
handler, so the theorems below hold for any handler, `Http.handle` included.

Assumptions on the loop (zig/src/serve.zig), not proved here: it performs
exactly the returned action, reports its outcome as the next event (except
after `close`, which ends the connection and frees the state), never receives
more than `room` bytes, and reports `sent n` only for bytes of the send it was
given, which may be a prefix of the remaining data. -/

namespace Conn

/-- Bytes a connection may buffer: the largest request `parse` accepts
(maxHeadBytes, CRLFCRLF, maxBodyBytes). -/
def inCap : Nat := maxHeadBytes + 4 + maxBodyBytes

inductive Phase where
  /-- Waiting for bytes from the peer. -/
  | reading
  /-- Sending `out` from offset `off`; closing after its last byte when `closeAfter`. -/
  | writing (out : ByteArray) (off : Nat) (closeAfter : Bool)
  /-- The close action was issued; nothing more happens. -/
  | closed

structure State where
  /-- Received bytes not yet consumed by a response. -/
  buf : ByteArray
  phase : Phase

/-- The outcome of the loop's last operation. -/
inductive Event where
  /-- A receive returned `data`; empty means the peer closed its side. -/
  | received (data : ByteArray)
  /-- A send wrote `n` bytes. -/
  | sent (n : Nat)
  /-- The operation failed. -/
  | failed

/-- What the loop does next. -/
inductive Action where
  /-- Receive at most `room` bytes. -/
  | recv (room : Nat)
  /-- Send `data` from offset `off`. -/
  | send (data : ByteArray) (off : Nat)
  /-- Close the socket; the connection is finished. -/
  | close
  /-- Nothing; the answer to any event after close. -/
  | none

def initial : State := { buf := ByteArray.emptyWithCapacity inCap, phase := .reading }

def closeNow : State × Action := ({ buf := ByteArray.empty, phase := .closed }, .close)

/-- Answers what is buffered: a response to send, a receive for more bytes, or a close. -/
def serve (handler : ByteArray → Reply) (buf : ByteArray) : State × Action :=
  match handler buf with
  | .needMore =>
    if buf.size < inCap then ({ buf, phase := .reading }, .recv (inCap - buf.size))
    else closeNow
  | .respond consumed response close =>
    if 0 < consumed ∧ consumed ≤ buf.size ∧ 0 < response.size then
      ({ buf := buf.extract consumed buf.size, phase := .writing response 0 close }, .send response 0)
    else closeNow

def step (handler : ByteArray → Reply) (s : State) (e : Event) : State × Action :=
  match s.phase, e with
  | .closed, _ => (s, .none)
  | _, .failed => closeNow
  | .reading, .received data =>
    if data.size = 0 then closeNow
    else if s.buf.size + data.size ≤ inCap then serve handler (s.buf ++ data)
    else closeNow
  | .writing out off closeAfter, .sent n =>
    if n = 0 ∨ out.size < off + n then closeNow
    else if off + n < out.size then ({ s with phase := .writing out (off + n) closeAfter }, .send out (off + n))
    else if closeAfter then closeNow
    else if 0 < s.buf.size then serve handler s.buf
    else ({ s with phase := .reading }, .recv inCap)
  | _, _ => closeNow

/-! ## Guarantees -/

/-- The buffer bound the loop's receive buffer is sized by. -/
def Inv (s : State) : Prop := s.buf.size ≤ inCap

theorem closeNow_inv : Inv closeNow.1 := by
  simp [Inv, closeNow]

theorem serve_inv (handler : ByteArray → Reply) (buf : ByteArray) (hb : buf.size ≤ inCap) :
    Inv (serve handler buf).1 := by
  unfold serve
  split
  · split
    · simp [Inv]; omega
    · exact closeNow_inv
  · split
    · simp [Inv]; omega
    · exact closeNow_inv

/-- Every step keeps the buffer within `inCap`. -/
theorem step_inv (handler : ByteArray → Reply) (s : State) (e : Event) (hs : Inv s) :
    Inv (step handler s e).1 := by
  unfold step
  split
  · exact hs
  · exact closeNow_inv
  · split
    · exact closeNow_inv
    · split
      · apply serve_inv; simp [ByteArray.size_append]; omega
      · exact closeNow_inv
  · split
    · exact closeNow_inv
    · split
      · exact hs
      · split
        · exact closeNow_inv
        · split
          · exact serve_inv _ _ hs
          · exact hs
  · exact closeNow_inv

/-- A closed connection stays closed and asks for nothing. -/
theorem step_closed (handler : ByteArray → Reply) (s : State) (e : Event) (h : s.phase = .closed) :
    step handler s e = (s, .none) := by
  unfold step; rw [h]

theorem serve_close (handler : ByteArray → Reply) (buf : ByteArray) :
    (serve handler buf).2 = .close → (serve handler buf).1.phase = .closed := by
  unfold serve
  split
  · split <;> simp [closeNow]
  · split <;> simp [closeNow]

/-- The close action always leaves the connection closed, so nothing follows it. -/
theorem step_close (handler : ByteArray → Reply) (s : State) (e : Event) :
    (step handler s e).2 = .close → (step handler s e).1.phase = .closed := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_close _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · simp
      · split
        · simp [closeNow]
        · split
          · exact serve_close _ _
          · simp
  · simp [closeNow]

theorem serve_recv (handler : ByteArray → Reply) (buf : ByteArray) (room : Nat) :
    (serve handler buf).2 = .recv room →
      0 < room ∧ (serve handler buf).1.buf.size + room = inCap := by
  unfold serve
  split
  · split
    · simp; omega
    · simp [closeNow]
  · split <;> simp [closeNow]

/-- A receive always has room, and never more than the buffer can take. -/
theorem step_recv (handler : ByteArray → Reply) (s : State) (e : Event) (room : Nat) :
    (step handler s e).2 = .recv room →
      0 < room ∧ (step handler s e).1.buf.size + room = inCap := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_recv _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · simp
      · split
        · simp [closeNow]
        · split
          · exact serve_recv _ _ _
          · intro h
            simp only [Action.recv.injEq] at h
            subst h
            simp_all [inCap, maxHeadBytes, maxBodyBytes]
  · simp [closeNow]

theorem serve_send (handler : ByteArray → Reply) (buf data : ByteArray) (off : Nat) :
    (serve handler buf).2 = .send data off → off < data.size := by
  unfold serve
  split
  · split <;> simp [closeNow]
  · split
    · rename_i h; simp only [Action.send.injEq]; rintro ⟨rfl, rfl⟩; omega
    · simp [closeNow]

/-- Every send starts inside its data, so it has at least one byte to write. -/
theorem step_send (handler : ByteArray → Reply) (s : State) (e : Event) (data : ByteArray) (off : Nat) :
    (step handler s e).2 = .send data off → off < data.size := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_send _ _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · rename_i h; simp only [Action.send.injEq]; rintro ⟨rfl, rfl⟩; exact h
      · split
        · simp [closeNow]
        · split
          · exact serve_send _ _ _ _
          · simp
  · simp [closeNow]

/-! ## The loop's entry points (zig/src/serve.zig through glue.c) -/

/-- A new connection: the initial state and its first action, a receive. -/
@[export ekk_conn_open]
def connOpen (_ : UInt8) : State × Action := (initial, .recv inCap)

@[export ekk_conn_on_recv]
def onRecv (now : UInt64) (s : State) (data : ByteArray) : State × Action :=
  step (handle now.toNat) s (.received data)

@[export ekk_conn_on_sent]
def onSent (now : UInt64) (s : State) (n : USize) : State × Action :=
  step (handle now.toNat) s (.sent n.toNat)

@[export ekk_conn_on_fail]
def onFail (s : State) : State × Action :=
  step (handle 0) s .failed

end Conn
