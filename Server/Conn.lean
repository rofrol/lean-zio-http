import Server.Wire

/-! The lifecycle of one connection, owned by Lean.

The zio.ev loop (zig/src/serve.zig) keeps no buffer or protocol state of its
own: it reports the outcome of the operation it last performed as an `Event`,
and performs the `Action` that `step` returns. `step` is pure and generic over
the protocol adapter (`ByteArray → Reply`), so the theorems below hold for any
adapter, `Server.H1Adapter.handle` included.

Assumptions on the loop, not proved here: it performs exactly the returned
action, except that it may decline a `recv` while it shuts down and report
`refused` instead; it reports the outcome as the next event (except after
`close`, which ends the connection and frees the state); it never receives
more than `room` bytes; and it reports `sent n` only for bytes of the send it
was given, which may be a prefix of the remaining data.

Effects precede their record: a receive or send has happened in the kernel
before its event reaches `step`, and a close is chosen before it is performed.
All of this state is volatile; nothing survives the process, so a crash
between an effect and its record can leave a peer with a prefix of a response
(possibly empty) and an unanswered request (README, "Production contract"). -/

namespace Server.Conn

/-- Where a connection goes once its current send is complete. -/
inductive Next where
  | close
  /-- Back to the buffered bytes; `continued` when the send was the interim
  `100 Continue` for the request at the buffer's start. -/
  | read (continued : Bool)

inductive Phase where
  /-- Waiting for bytes from the peer; `continued` when `100 Continue` was sent
  for the request at the buffer's start. -/
  | reading (continued : Bool)
  /-- Sending `out` from offset `off`, then going on as `next` says. -/
  | writing (out : ByteArray) (off : Nat) (next : Next)
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
  /-- The loop is shutting down and declined (or canceled) the receive it was
  asked for; it performs no further receive on this connection. -/
  | refused

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

def initial : State := { buf := ByteArray.emptyWithCapacity inCap, phase := .reading false }

def closeNow : State × Action := ({ buf := ByteArray.empty, phase := .closed }, .close)

/-- Waits for more bytes of the request at the start of `buf`, or closes when
the buffer is full. -/
def wait (continued : Bool) (buf : ByteArray) : State × Action :=
  if buf.size < inCap then ({ buf, phase := .reading continued }, .recv (inCap - buf.size))
  else closeNow

/-- Starts sending `out` (1 to `maxResponseBytes` bytes), or closes when it is
empty or larger. -/
def startSend (buf out : ByteArray) (next : Next) : State × Action :=
  if 0 < out.size ∧ out.size ≤ maxResponseBytes then ({ buf, phase := .writing out 0 next }, .send out 0)
  else closeNow

/-- Answers what is buffered: a response to send, the interim `100 Continue`,
a receive for more bytes, or a close. -/
def serve (handler : ByteArray → Reply) (continued : Bool) (buf : ByteArray) : State × Action :=
  match handler buf with
  | .needMore => wait continued buf
  | .continue interim => if continued then wait true buf else startSend buf interim (.read true)
  | .respond consumed response close =>
    if 0 < consumed ∧ consumed ≤ buf.size then
      startSend (buf.extract consumed buf.size) response (if close then .close else .read false)
    else closeNow

def step (handler : ByteArray → Reply) (s : State) (e : Event) : State × Action :=
  match s.phase, e with
  | .closed, _ => (s, .none)
  | _, .failed => closeNow
  | _, .refused => closeNow
  | .reading continued, .received data =>
    if data.size = 0 then closeNow
    else if s.buf.size + data.size ≤ inCap then serve handler continued (s.buf ++ data)
    else closeNow
  | .writing out off next, .sent n =>
    if n = 0 ∨ out.size < off + n then closeNow
    else if off + n < out.size then ({ s with phase := .writing out (off + n) next }, .send out (off + n))
    else match next with
      | .close => closeNow
      | .read continued =>
        if 0 < s.buf.size then serve handler continued s.buf
        else ({ s with phase := .reading continued }, .recv inCap)
  | _, _ => closeNow

/-! ## Guarantees -/

/-- The memory bound: the buffer never exceeds `inCap`, and a response being
sent never exceeds `maxResponseBytes`. -/
def Inv (s : State) : Prop :=
  s.buf.size ≤ inCap ∧ ∀ out off next, s.phase = .writing out off next → out.size ≤ maxResponseBytes

theorem closeNow_inv : Inv closeNow.1 := by
  simp [Inv, closeNow]

theorem wait_inv (c : Bool) (buf : ByteArray) : Inv (wait c buf).1 := by
  unfold wait; split
  · simp [Inv]; omega
  · exact closeNow_inv

theorem startSend_inv (buf out : ByteArray) (next : Next) (hb : buf.size ≤ inCap) :
    Inv (startSend buf out next).1 := by
  unfold startSend; split
  · rename_i h; refine ⟨hb, ?_⟩; intro o off n hp; simp at hp; obtain ⟨rfl, -, -⟩ := hp; omega
  · exact closeNow_inv

theorem serve_inv (handler : ByteArray → Reply) (c : Bool) (buf : ByteArray) (hb : buf.size ≤ inCap) :
    Inv (serve handler c buf).1 := by
  unfold serve
  split
  · exact wait_inv _ _
  · split
    · exact wait_inv _ _
    · exact startSend_inv _ _ _ hb
  · split
    · apply startSend_inv; simp [ByteArray.size_extract]; omega
    · exact closeNow_inv

/-- Every step keeps the buffer within `inCap` and the response within `maxResponseBytes`. -/
theorem step_inv (handler : ByteArray → Reply) (s : State) (e : Event) (hs : Inv s) :
    Inv (step handler s e).1 := by
  obtain ⟨hb, hw⟩ := hs
  unfold step
  split
  · exact ⟨hb, hw⟩
  · exact closeNow_inv
  · exact closeNow_inv
  · split
    · exact closeNow_inv
    · split
      · apply serve_inv; simp [ByteArray.size_append]; omega
      · exact closeNow_inv
  · rename_i out off next _ hp
    split
    · exact closeNow_inv
    · split
      · refine ⟨hb, ?_⟩; intro o f n h; simp at h; obtain ⟨rfl, -, -⟩ := h; exact hw _ _ _ hp
      · split
        · exact closeNow_inv
        · split
          · exact serve_inv _ _ _ hb
          · refine ⟨hb, ?_⟩; intro o f n h; simp at h
  · exact closeNow_inv

/-- A closed connection stays closed and asks for nothing. -/
theorem step_closed (handler : ByteArray → Reply) (s : State) (e : Event) (h : s.phase = .closed) :
    step handler s e = (s, .none) := by
  unfold step; rw [h]

/-- A declined receive always closes the connection. -/
theorem step_refused (handler : ByteArray → Reply) (s : State) (h : s.phase ≠ .closed) :
    step handler s .refused = closeNow := by
  unfold step; split <;> simp_all

theorem wait_close (c : Bool) (buf : ByteArray) :
    (wait c buf).2 = .close → (wait c buf).1.phase = .closed := by
  unfold wait; split <;> simp [closeNow]

theorem startSend_close (buf out : ByteArray) (next : Next) :
    (startSend buf out next).2 = .close → (startSend buf out next).1.phase = .closed := by
  unfold startSend; split <;> simp [closeNow]

theorem serve_close (handler : ByteArray → Reply) (c : Bool) (buf : ByteArray) :
    (serve handler c buf).2 = .close → (serve handler c buf).1.phase = .closed := by
  unfold serve
  split
  · exact wait_close _ _
  · split
    · exact wait_close _ _
    · exact startSend_close _ _ _
  · split
    · exact startSend_close _ _ _
    · simp [closeNow]

/-- The close action always leaves the connection closed, so nothing follows it. -/
theorem step_close (handler : ByteArray → Reply) (s : State) (e : Event) :
    (step handler s e).2 = .close → (step handler s e).1.phase = .closed := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_close _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · simp
      · split
        · simp [closeNow]
        · split
          · exact serve_close _ _ _
          · simp
  · simp [closeNow]

theorem wait_recv (c : Bool) (buf : ByteArray) (room : Nat) :
    (wait c buf).2 = .recv room → 0 < room ∧ (wait c buf).1.buf.size + room = inCap := by
  unfold wait; split
  · simp; omega
  · simp [closeNow]

theorem startSend_recv (buf out : ByteArray) (next : Next) (room : Nat) :
    (startSend buf out next).2 ≠ .recv room := by
  unfold startSend; split <;> simp [closeNow]

theorem serve_recv (handler : ByteArray → Reply) (c : Bool) (buf : ByteArray) (room : Nat) :
    (serve handler c buf).2 = .recv room →
      0 < room ∧ (serve handler c buf).1.buf.size + room = inCap := by
  unfold serve
  split
  · exact wait_recv _ _ _
  · split
    · exact wait_recv _ _ _
    · intro h; exact absurd h (startSend_recv _ _ _ _)
  · split
    · intro h; exact absurd h (startSend_recv _ _ _ _)
    · simp [closeNow]

/-- A receive always has room, and never more than the buffer can take. -/
theorem step_recv (handler : ByteArray → Reply) (s : State) (e : Event) (room : Nat) :
    (step handler s e).2 = .recv room →
      0 < room ∧ (step handler s e).1.buf.size + room = inCap := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_recv _ _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · simp
      · split
        · simp [closeNow]
        · split
          · exact serve_recv _ _ _ _
          · intro h
            simp only [Action.recv.injEq] at h
            subst h
            simp_all [inCap, maxHeadBytes, maxBodyBytes]
  · simp [closeNow]

theorem startSend_send (buf out data : ByteArray) (next : Next) (off : Nat) :
    (startSend buf out next).2 = .send data off → off < data.size := by
  unfold startSend; split
  · rename_i h; simp only [Action.send.injEq]; rintro ⟨rfl, rfl⟩; omega
  · simp [closeNow]

theorem serve_send (handler : ByteArray → Reply) (c : Bool) (buf data : ByteArray) (off : Nat) :
    (serve handler c buf).2 = .send data off → off < data.size := by
  unfold serve
  split
  · unfold wait; split <;> simp [closeNow]
  · split
    · unfold wait; split <;> simp [closeNow]
    · exact startSend_send _ _ _ _ _
  · split
    · exact startSend_send _ _ _ _ _
    · simp [closeNow]

/-- Every send starts inside its data, so it has at least one byte to write. -/
theorem step_send (handler : ByteArray → Reply) (s : State) (e : Event) (data : ByteArray) (off : Nat) :
    (step handler s e).2 = .send data off → off < data.size := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_send _ _ _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · rename_i h; simp only [Action.send.injEq]; rintro ⟨rfl, rfl⟩; exact h
      · split
        · simp [closeNow]
        · split
          · exact serve_send _ _ _ _ _
          · simp
  · simp [closeNow]

/-- The interim response is sent at most once per request: serving a request
for which `100 Continue` was already sent never starts another interim send. -/
theorem serve_continued (handler : ByteArray → Reply) (buf : ByteArray) (out : ByteArray) (off : Nat)
    (h : (serve handler true buf).1.phase = .writing out off (.read true)) : False := by
  revert h
  unfold serve
  split
  · unfold wait; split <;> simp [closeNow]
  · simp only [ite_true]; unfold wait; split <;> simp [closeNow]
  · split
    · unfold startSend; split
      · simp; split <;> simp
      · simp [closeNow]
    · simp [closeNow]

end Server.Conn
