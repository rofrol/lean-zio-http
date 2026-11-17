import Server.Wire

/-! The lifecycle of one connection, owned by Lean.

The zio.ev loop (zig/src/serve.zig) keeps no buffer or protocol state of its
own: it reports the outcome of the operation it last performed as an `Event`,
and performs the `Action` that `step` returns. `step` is pure and generic over
the protocol adapter (`Server.Adapter σ`), so the theorems below hold for any
adapter, `Server.H1Adapter.adapter` included. The adapter's parse state lives
in `State.parser` while a request is incomplete and is `init` again once a
request is consumed. `step_fed` proves that every call of the adapter gets a
state `Fed` for its buffer, whatever the events, so an adapter that keeps the
law `Adapter.Incremental` answers each buffer as from `init`; `fragments`
proves that receives each answered with another receive end as their
concatenation received at once.

Each event comes with the wall clock it is reported at, which `step` passes
only to the response it sends (`Server.Dated`); the adapter is one value, and
neither `initial` nor the adapter's state sees the clock, so `run_inv` holds
for any timestamps.

Assumptions on the loop, not proved here: it performs exactly the returned
action, except that it may decline a `recv` while it shuts down and report
`refused` instead; it reports the outcome as the next event (except after
`close`, which ends the connection and frees the state); it never receives
more than `room` bytes; it reports `sent n` only for bytes of the send it
was given, which may be a prefix of the remaining data; and it answers a
`query` action with exactly one `answered` event, the query's result.

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
  /-- Waiting for the result of the query just asked for, then going on with
  `k`; the request is already consumed from `buf`, and no receive is in
  flight, so bytes the peer pipelines wait in the kernel. -/
  | querying (k : Query.Result → Await Dated)
  /-- The close action was issued; nothing more happens. -/
  | closed

structure State (σ : Type) where
  /-- Received bytes not yet consumed by a response. -/
  buf : ByteArray
  /-- What the adapter kept about the request at the start of `buf`
  (`Adapter.Fed`, `step_fed`). -/
  parser : σ
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
  /-- The query asked for answered `r`. -/
  | answered (r : Query.Result)

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
  /-- Run query `q` and report its result as `answered`. -/
  | query (q : Query)

variable {σ : Type} (ad : Adapter σ)

def initial : State σ := { buf := ByteArray.emptyWithCapacity inCap, parser := ad.init, phase := .reading false }

def closeNow : State σ × Action := ({ buf := ByteArray.empty, parser := ad.init, phase := .closed }, .close)

/-- Waits for more bytes of the request at the start of `buf`, keeping the
adapter's state `p`, or closes when the buffer is full. -/
def wait (continued : Bool) (p : σ) (buf : ByteArray) : State σ × Action :=
  if buf.size < inCap then ({ buf, parser := p, phase := .reading continued }, .recv (inCap - buf.size))
  else closeNow ad

/-- Starts sending `out` (1 to `maxResponseBytes` bytes), or closes when it is
empty or larger. -/
def startSend (p : σ) (buf out : ByteArray) (next : Next) : State σ × Action :=
  if 0 < out.size ∧ out.size ≤ maxResponseBytes then ({ buf, parser := p, phase := .writing out 0 next }, .send out 0)
  else closeNow ad

/-- Goes on with a request's answer at wall clock `now`, `buf` holding the
bytes after it, which start the next request (so the adapter starts again
from `init`): sends a complete answer written at `now` (then closes or reads
on, as it says), or asks for the query it waits for. Both a `respond` and an
answered query come through here. -/
def resume (now : Nat) (buf : ByteArray) : Await Dated → State σ × Action
  | .done f =>
    let r := f now
    startSend ad ad.init buf r.1 (if r.2 then .close else .read false)
  | .query q k => ({ buf, parser := ad.init, phase := .querying k }, .query q)

/-- Answers what is buffered at wall clock `now`, given the adapter's state
`p` for it: a response to send, a query to run, the interim `100 Continue`, a
receive for more bytes, or a close. -/
def serve (now : Nat) (continued : Bool) (p : σ) (buf : ByteArray) : State σ × Action :=
  match (ad.handle p buf).2 with
  | .needMore => wait ad continued (ad.handle p buf).1 buf
  | .continue interim =>
    if continued then wait ad true (ad.handle p buf).1 buf else startSend ad (ad.handle p buf).1 buf interim (.read true)
  | .respond consumed response =>
    if 0 < consumed ∧ consumed ≤ buf.size then resume ad now (buf.extract consumed buf.size) (.done response)
    else closeNow ad
  | .await consumed q k =>
    if 0 < consumed ∧ consumed ≤ buf.size then resume ad now (buf.extract consumed buf.size) (.query q k)
    else closeNow ad

/-- The connection's answer to event `e`, reported at wall clock `now` (Unix
seconds), which only a response sent in answer to it sees (`Dated`). -/
def step (now : Nat) (s : State σ) (e : Event) : State σ × Action :=
  match s.phase, e with
  | .closed, _ => (s, .none)
  | _, .failed => closeNow ad
  | _, .refused => closeNow ad
  | .reading continued, .received data =>
    if data.size = 0 then closeNow ad
    else if s.buf.size + data.size ≤ inCap then serve ad now continued s.parser (s.buf ++ data)
    else closeNow ad
  | .writing out off next, .sent n =>
    if n = 0 ∨ out.size < off + n then closeNow ad
    else if off + n < out.size then ({ s with phase := .writing out (off + n) next }, .send out (off + n))
    else match next with
      | .close => closeNow ad
      | .read continued =>
        if 0 < s.buf.size then serve ad now continued s.parser s.buf
        else ({ s with phase := .reading continued }, .recv inCap)
  | .querying k, .answered r => resume ad now s.buf (k r)
  | _, _ => closeNow ad

/-! ## Guarantees

Every theorem holds at any wall clock `now`, which a step only passes to the
response it sends. -/

variable (now : Nat)

/-- The length bound: the buffer never exceeds `inCap`, and a response being
sent never exceeds `maxResponseBytes`. Lengths, not capacities: what the
connection allocates is derived from these in README "Memory". -/
def Inv (s : State σ) : Prop :=
  s.buf.size ≤ inCap ∧ ∀ out off next, s.phase = .writing out off next → out.size ≤ maxResponseBytes

theorem closeNow_inv : Inv (closeNow ad).1 := by
  simp [Inv, closeNow]

theorem wait_inv (c : Bool) (p : σ) (buf : ByteArray) : Inv (wait ad c p buf).1 := by
  unfold wait; split
  · simp [Inv]; omega
  · exact closeNow_inv ad

theorem startSend_inv (p : σ) (buf out : ByteArray) (next : Next) (hb : buf.size ≤ inCap) :
    Inv (startSend ad p buf out next).1 := by
  unfold startSend; split
  · rename_i h; refine ⟨hb, ?_⟩; intro o off n hp; simp at hp; obtain ⟨rfl, -, -⟩ := hp; omega
  · exact closeNow_inv ad

theorem resume_inv (buf : ByteArray) (a : Await Dated) (hb : buf.size ≤ inCap) :
    Inv (resume ad now buf a).1 := by
  match a with
  | .done f => exact startSend_inv ad _ _ _ _ hb
  | .query q k => exact ⟨hb, by intro o off n h; simp [resume] at h⟩

theorem serve_inv (c : Bool) (p : σ) (buf : ByteArray) (hb : buf.size ≤ inCap) :
    Inv (serve ad now c p buf).1 := by
  unfold serve
  split
  · exact wait_inv ad _ _ _
  · split
    · exact wait_inv ad _ _ _
    · exact startSend_inv ad _ _ _ _ hb
  · split
    · apply resume_inv; simp [ByteArray.size_extract]; omega
    · exact closeNow_inv ad
  · split
    · apply resume_inv; simp [ByteArray.size_extract]; omega
    · exact closeNow_inv ad

/-- Every step keeps the buffer within `inCap` and the response within
`maxResponseBytes`, whatever a query's continuation answers. -/
theorem step_inv (s : State σ) (e : Event) (hs : Inv s) : Inv (step ad now s e).1 := by
  obtain ⟨hb, hw⟩ := hs
  unfold step
  split
  · exact ⟨hb, hw⟩
  · exact closeNow_inv ad
  · exact closeNow_inv ad
  · split
    · exact closeNow_inv ad
    · split
      · apply serve_inv; simp [ByteArray.size_append]; omega
      · exact closeNow_inv ad
  · rename_i out off next _ hp
    split
    · exact closeNow_inv ad
    · split
      · refine ⟨hb, ?_⟩; intro o f n h; simp at h; obtain ⟨rfl, -, -⟩ := h; exact hw _ _ _ hp
      · split
        · exact closeNow_inv ad
        · split
          · exact serve_inv ad now _ _ _ hb
          · refine ⟨hb, ?_⟩; intro o f n h; simp at h
  · exact resume_inv ad now _ _ hb
  · exact closeNow_inv ad

/-- A closed connection stays closed and asks for nothing. -/
theorem step_closed (s : State σ) (e : Event) (h : s.phase = .closed) :
    step ad now s e = (s, .none) := by
  unfold step; rw [h]

/-- A declined receive always closes the connection. -/
theorem step_refused (s : State σ) (h : s.phase ≠ .closed) :
    step ad now s .refused = closeNow ad := by
  unfold step; split <;> simp_all

theorem wait_close (c : Bool) (p : σ) (buf : ByteArray) :
    (wait ad c p buf).2 = .close → (wait ad c p buf).1.phase = .closed := by
  unfold wait; split <;> simp [closeNow]

theorem startSend_close (p : σ) (buf out : ByteArray) (next : Next) :
    (startSend ad p buf out next).2 = .close → (startSend ad p buf out next).1.phase = .closed := by
  unfold startSend; split <;> simp [closeNow]

theorem resume_close (buf : ByteArray) (a : Await Dated) :
    (resume ad now buf a).2 = .close → (resume ad now buf a).1.phase = .closed := by
  match a with
  | .done f => exact startSend_close ad _ _ _ _
  | .query q k => simp [resume]

theorem serve_close (c : Bool) (p : σ) (buf : ByteArray) :
    (serve ad now c p buf).2 = .close → (serve ad now c p buf).1.phase = .closed := by
  unfold serve
  split
  · exact wait_close ad _ _ _
  · split
    · exact wait_close ad _ _ _
    · exact startSend_close ad _ _ _ _
  · split
    · exact resume_close ad now _ _
    · simp [closeNow]
  · split
    · exact resume_close ad now _ _
    · simp [closeNow]

/-- The close action always leaves the connection closed, so nothing follows it. -/
theorem step_close (s : State σ) (e : Event) :
    (step ad now s e).2 = .close → (step ad now s e).1.phase = .closed := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_close ad now _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · simp
      · split
        · simp [closeNow]
        · split
          · exact serve_close ad now _ _ _
          · simp
  · exact resume_close ad now _ _
  · simp [closeNow]

theorem wait_recv (c : Bool) (p : σ) (buf : ByteArray) (room : Nat) :
    (wait ad c p buf).2 = .recv room → 0 < room ∧ (wait ad c p buf).1.buf.size + room = inCap := by
  unfold wait; split
  · simp; omega
  · simp [closeNow]

theorem startSend_recv (p : σ) (buf out : ByteArray) (next : Next) (room : Nat) :
    (startSend ad p buf out next).2 ≠ .recv room := by
  unfold startSend; split <;> simp [closeNow]

theorem resume_recv (buf : ByteArray) (a : Await Dated) (room : Nat) :
    (resume ad now buf a).2 ≠ .recv room := by
  match a with
  | .done f => exact startSend_recv ad _ _ _ _ _
  | .query q k => simp [resume]

theorem serve_recv (c : Bool) (p : σ) (buf : ByteArray) (room : Nat) :
    (serve ad now c p buf).2 = .recv room →
      0 < room ∧ (serve ad now c p buf).1.buf.size + room = inCap := by
  unfold serve
  split
  · exact wait_recv ad _ _ _ _
  · split
    · exact wait_recv ad _ _ _ _
    · intro h; exact absurd h (startSend_recv ad _ _ _ _ _)
  · split
    · intro h; exact absurd h (resume_recv ad now _ _ _)
    · simp [closeNow]
  · split
    · intro h; exact absurd h (resume_recv ad now _ _ _)
    · simp [closeNow]

/-- A receive always has room, and never more than the buffer can take. -/
theorem step_recv (s : State σ) (e : Event) (room : Nat) :
    (step ad now s e).2 = .recv room →
      0 < room ∧ (step ad now s e).1.buf.size + room = inCap := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_recv ad now _ _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · simp
      · split
        · simp [closeNow]
        · split
          · exact serve_recv ad now _ _ _ _
          · intro h
            simp only [Action.recv.injEq] at h
            subst h
            simp_all [inCap, maxHeadBytes, maxBodyBytes]
  · intro h; exact absurd h (resume_recv ad now _ _ _)
  · simp [closeNow]

theorem startSend_send (p : σ) (buf out data : ByteArray) (next : Next) (off : Nat) :
    (startSend ad p buf out next).2 = .send data off → off < data.size := by
  unfold startSend; split
  · rename_i h; simp only [Action.send.injEq]; rintro ⟨rfl, rfl⟩; omega
  · simp [closeNow]

theorem resume_send (buf data : ByteArray) (a : Await Dated) (off : Nat) :
    (resume ad now buf a).2 = .send data off → off < data.size := by
  match a with
  | .done f => exact startSend_send ad _ _ _ _ _ _
  | .query q k => simp [resume]

theorem serve_send (c : Bool) (p : σ) (buf data : ByteArray) (off : Nat) :
    (serve ad now c p buf).2 = .send data off → off < data.size := by
  unfold serve
  split
  · unfold wait; split <;> simp [closeNow]
  · split
    · unfold wait; split <;> simp [closeNow]
    · exact startSend_send ad _ _ _ _ _ _
  · split
    · exact resume_send ad now _ _ _ _
    · simp [closeNow]
  · split
    · exact resume_send ad now _ _ _ _
    · simp [closeNow]

/-- Every send starts inside its data, so it has at least one byte to write. -/
theorem step_send (s : State σ) (e : Event) (data : ByteArray) (off : Nat) :
    (step ad now s e).2 = .send data off → off < data.size := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_send ad now _ _ _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · rename_i h; simp only [Action.send.injEq]; rintro ⟨rfl, rfl⟩; exact h
      · split
        · simp [closeNow]
        · split
          · exact serve_send ad now _ _ _ _ _
          · simp
  · exact resume_send ad now _ _ _ _
  · simp [closeNow]

theorem resume_query (buf : ByteArray) (a : Await Dated) (q : Query) :
    (resume ad now buf a).2 = .query q → ∃ k, (resume ad now buf a).1.phase = .querying k := by
  match a with
  | .done f =>
    intro h; simp only [resume, startSend] at h; split at h <;> simp [closeNow] at h
  | .query q' k => intro _; exact ⟨k, rfl⟩

theorem serve_query (c : Bool) (p : σ) (buf : ByteArray) (q : Query) :
    (serve ad now c p buf).2 = .query q → ∃ k, (serve ad now c p buf).1.phase = .querying k := by
  unfold serve
  split
  · unfold wait; split <;> simp [closeNow]
  · split
    · unfold wait; split <;> simp [closeNow]
    · unfold startSend; split <;> simp [closeNow]
  · split
    · exact resume_query ad now _ _ _
    · simp [closeNow]
  · split
    · exact resume_query ad now _ _ _
    · simp [closeNow]

/-- A query is asked for only together with the phase that waits for its
result. So, provided the loop answers each `query` action with exactly one
`answered` event and reports nothing else meanwhile (the assumption in this
file's header, which the loop checks at run time, `serve.zig` `answered`),
a connection has at most one query outstanding and that event finds its
continuation. -/
theorem step_query (s : State σ) (e : Event) (q : Query) :
    (step ad now s e).2 = .query q → ∃ k, (step ad now s e).1.phase = .querying k := by
  unfold step
  split
  · simp
  · simp [closeNow]
  · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · exact serve_query ad now _ _ _ _
      · simp [closeNow]
  · split
    · simp [closeNow]
    · split
      · simp
      · split
        · simp [closeNow]
        · split
          · exact serve_query ad now _ _ _ _
          · simp
  · exact resume_query ad now _ _ _
  · simp [closeNow]

/-- The interim response is sent at most once per request: serving a request
for which `100 Continue` was already sent never starts another interim send. -/
theorem serve_continued (p : σ) (buf : ByteArray) (out : ByteArray) (off : Nat)
    (h : (serve ad now true p buf).1.phase = .writing out off (.read true)) : False := by
  revert h
  unfold serve
  split
  · unfold wait; split <;> simp [closeNow]
  · simp only [ite_true]; unfold wait; split <;> simp [closeNow]
  · split
    · intro h
      simp only [resume, startSend] at h
      split at h
      · simp at h; split at h <;> simp at h
      · simp [closeNow] at h
    · simp [closeNow]
  · split
    · simp [resume]
    · simp [closeNow]

/-! ## The adapter's kept state -/

/-- The adapter's state on a connection is always one the adapter may be
handed with the buffer (`Adapter.Fed`): `init`, or what it kept for a prefix
of the buffer while the request was incomplete. -/
def FedInv (s : State σ) : Prop := ad.Fed s.parser s.buf

theorem closeNow_fed : FedInv ad (closeNow ad).1 := .init _

theorem wait_fed (c : Bool) (p : σ) (buf : ByteArray) (h : ad.Fed p buf) : FedInv ad (wait ad c p buf).1 := by
  unfold wait; split
  · exact h
  · exact closeNow_fed ad

theorem startSend_fed (p : σ) (buf out : ByteArray) (next : Next) (h : ad.Fed p buf) :
    FedInv ad (startSend ad p buf out next).1 := by
  unfold startSend; split
  · exact h
  · exact closeNow_fed ad

theorem resume_fed (buf : ByteArray) (a : Await Dated) : FedInv ad (resume ad now buf a).1 := by
  match a with
  | .done f => exact startSend_fed ad _ _ _ _ (.init _)
  | .query q k => exact .init _

/-- What `handle` kept for `buf` while it waited is fed for `buf`. -/
theorem Fed.kept {p : σ} {buf : ByteArray} (h : ad.Fed p buf) (w : (ad.handle p buf).2.waits) :
    ad.Fed (ad.handle p buf).1 buf := by
  have := Adapter.Fed.more (ad := ad) ByteArray.empty h w
  rwa [ByteArray.append_empty] at this

theorem serve_fed (c : Bool) (p : σ) (buf : ByteArray) (h : ad.Fed p buf) : FedInv ad (serve ad now c p buf).1 := by
  unfold serve
  split
  · rename_i hr; exact wait_fed ad _ _ _ (Fed.kept ad h (by rw [hr]; rfl))
  · rename_i hr
    have hk := Fed.kept ad h (by rw [hr]; rfl)
    split
    · exact wait_fed ad _ _ _ hk
    · exact startSend_fed ad _ _ _ _ hk
  · split
    · exact resume_fed ad now _ _
    · exact closeNow_fed ad
  · split
    · exact resume_fed ad now _ _
    · exact closeNow_fed ad

/-- Every step keeps the adapter's state fed for the buffer. -/
theorem step_fed (s : State σ) (e : Event) (hs : FedInv ad s) : FedInv ad (step ad now s e).1 := by
  unfold step
  split
  · exact hs
  · exact closeNow_fed ad
  · exact closeNow_fed ad
  · split
    · exact closeNow_fed ad
    · split
      · exact serve_fed ad now _ _ _ (hs.extend ad _)
      · exact closeNow_fed ad
  · split
    · exact closeNow_fed ad
    · split
      · exact hs
      · split
        · exact closeNow_fed ad
        · split
          · exact serve_fed ad now _ _ _ hs
          · exact hs
  · exact resume_fed ad now _ _
  · exact closeNow_fed ad

/-- The state after the events `es`, each reported at its own wall clock. -/
def run (s : State σ) : List (Nat × Event) → State σ
  | [] => s
  | (t, e) :: es => run (step ad t s e).1 es

/-- Successive steps keep the length bound and the adapter's fed state,
whatever wall clock each event is reported at. With `initial`, which no clock
reaches, every state the transport holds keeps both. -/
theorem run_inv (es : List (Nat × Event)) : ∀ (s : State σ), Inv s → FedInv ad s → Inv (run ad s es) ∧ FedInv ad (run ad s es) := by
  induction es with
  | nil => intro s hi hf; exact ⟨hi, hf⟩
  | cons x es ih => intro s hi hf; exact ih _ (step_inv ad x.1 s x.2 hi) (step_fed ad x.1 s x.2 hf)

theorem initial_inv : Inv (initial ad) ∧ FedInv ad (initial ad) :=
  ⟨⟨Nat.zero_le _, by simp [initial]⟩, .init _⟩

/-- What a step leaves observable: the buffer, the phase and the action; the
adapter's state is left out, since only the adapter reads it. -/
def view (r : State σ × Action) : ByteArray × Phase × Action := (r.1.buf, r.1.phase, r.2)

theorem wait_view (c : Bool) (p p' : σ) (buf : ByteArray) : view (wait ad c p buf) = view (wait ad c p' buf) := by
  unfold wait; split <;> rfl

theorem startSend_view (p p' : σ) (buf out : ByteArray) (next : Next) :
    view (startSend ad p buf out next) = view (startSend ad p' buf out next) := by
  unfold startSend; split <;> rfl

/-- Two states of the adapter fed for the same buffer serve it alike, when
the adapter keeps its law. -/
theorem serve_congr (hI : ad.Incremental) (c : Bool) (p p' : σ) (buf : ByteArray)
    (h : ad.Fed p buf) (h' : ad.Fed p' buf) : view (serve ad now c p buf) = view (serve ad now c p' buf) := by
  have e : (ad.handle p buf).2 = (ad.handle p' buf).2 := by rw [hI _ _ h, hI _ _ h']
  unfold serve
  rw [e]
  split
  · exact wait_view ad _ _ _ _
  · split
    · exact wait_view ad _ _ _ _
    · exact startSend_view ad _ _ _ _ _
  · rfl
  · rfl

/-- A receive answered with another receive leaves the connection reading,
with the received bytes appended to its buffer. -/
theorem step_received_recv (s : State σ) (c : Bool) (hr : s.phase = .reading c) (d : ByteArray) (room : Nat)
    (h : (step ad now s (.received d)).2 = .recv room) :
    (step ad now s (.received d)).1.buf = s.buf ++ d ∧ (step ad now s (.received d)).1.phase = .reading c := by
  revert h
  unfold step
  rw [hr]
  simp only
  split
  · simp [closeNow]
  · split
    · unfold serve
      split
      · unfold wait; split <;> simp [closeNow]
      · split
        · rename_i hc; unfold wait; split <;> simp [closeNow, hc]
        · intro h; exact absurd h (startSend_recv ad _ _ _ _ _)
      · split
        · intro h; exact absurd h (resume_recv ad now _ _ _)
        · simp [closeNow]
      · split
        · intro h; exact absurd h (resume_recv ad now _ _ _)
        · simp [closeNow]
    · simp [closeNow]

/-- Receiving `d₁` at `t₁` and then `d₂` at `t₂` ends as receiving `d₁ ++ d₂`
at once at `t₂`, when the first receive was answered with another receive. -/
theorem step_split (hI : ad.Incremental) (s : State σ) (hs : FedInv ad s) (c : Bool) (hr : s.phase = .reading c)
    (t₁ t₂ : Nat) (d₁ d₂ : ByteArray) (h₁ : 0 < d₁.size) (h₂ : 0 < d₂.size) (room : Nat)
    (hrecv : (step ad t₁ s (.received d₁)).2 = .recv room) :
    view (step ad t₂ (step ad t₁ s (.received d₁)).1 (.received d₂)) = view (step ad t₂ s (.received (d₁ ++ d₂))) := by
  obtain ⟨hb, hp⟩ := step_received_recv ad t₁ s c hr d₁ room hrecv
  have hf := step_fed ad t₁ s (.received d₁) hs
  generalize step ad t₁ s (.received d₁) = r at hb hp hf
  obtain ⟨⟨buf, p, phase⟩, a⟩ := r
  simp only at hb hp hf
  subst hb hp
  unfold step
  rw [hr]
  simp only [ByteArray.size_append]
  have n₁ : ¬ d₂.size = 0 := by omega
  have n₂ : ¬ d₁.size + d₂.size = 0 := by omega
  simp only [n₁, n₂, ite_false, ← Nat.add_assoc]
  split
  · rw [ByteArray.append_assoc]
    have hp' : ad.Fed p (s.buf ++ (d₁ ++ d₂)) := by
      have := hf.extend ad d₂; simpa [ByteArray.append_assoc] using this
    exact serve_congr ad t₂ hI _ _ _ _ hp' (hs.extend ad (d₁ ++ d₂))
  · rfl

/-- The bytes of `ds` in order. -/
def concat (ds : List ByteArray) : ByteArray := ds.foldr (· ++ ·) ByteArray.empty

/-- Receives each of `ds` in turn, each fragment at its own wall clock; the
last step's result, when every receive before it was answered with another
receive. -/
def receiveAll (s : State σ) : List (Nat × ByteArray) → Option (State σ × Action)
  | [] => none
  | [(t, d)] => some (step ad t s (.received d))
  | (t, d) :: ds =>
    match step ad t s (.received d) with
    | (s', .recv _) => receiveAll s' ds
    | _ => none

/-- A request split into any fragments, received at any times, ends as it
does in one receive at the time of the last: for an adapter that keeps its
law, receiving the nonempty fragments `ds` one after another, while each but
the last is answered with another receive, leaves the same buffer and phase
and asks for the same action as receiving their concatenation at once. A
split across which the connection sends (the interim `100 Continue`, or a
response before pipelined bytes) is not covered here; there `step_fed` still
gives every call of the adapter a `Fed` state, so the adapter answers each
buffer as from `init`. -/
theorem fragments (hI : ad.Incremental) (ds : List (Nat × ByteArray)) (hne : ∀ x ∈ ds, 0 < x.2.size) :
    ∀ (s : State σ), FedInv ad s → ∀ (c : Bool), s.phase = .reading c →
      ∀ r t d, receiveAll ad s ds = some r → ds.getLast? = some (t, d) →
        view r = view (step ad t s (.received (concat (ds.map (·.2))))) := by
  induction ds with
  | nil => intro s _ c _ r t d h; simp [receiveAll] at h
  | cons x ds ih =>
    obtain ⟨t₁, d₁⟩ := x
    intro s hs c hr r t d h hl
    match ds, ih, hne, h, hl with
    | [], _, _, h, hl =>
      simp only [receiveAll, Option.some.injEq] at h
      simp only [List.getLast?_singleton, Option.some.injEq, Prod.mk.injEq] at hl
      obtain ⟨rfl, rfl⟩ := hl
      subst h
      simp [concat, ByteArray.append_empty]
    | x₂ :: ds', ih, hne, h, hl =>
      simp only [receiveAll] at h
      generalize hstep : step ad t₁ s (.received d₁) = st at h
      obtain ⟨s', a⟩ := st
      cases a with
      | recv room =>
        simp only at h
        have hrecv : (step ad t₁ s (.received d₁)).2 = .recv room := by rw [hstep]
        obtain ⟨-, hp⟩ := step_received_recv ad t₁ s c hr d₁ room hrecv
        have hf := step_fed ad t₁ s (.received d₁) hs
        rw [hstep] at hp hf
        have hne' : ∀ x ∈ x₂ :: ds', 0 < x.2.size := fun x hx => hne x (List.mem_cons_of_mem _ hx)
        rw [List.getLast?_cons_cons] at hl
        rw [ih hne' s' hf c hp r t d h hl]
        have hrest : 0 < (concat ((x₂ :: ds').map (·.2))).size := by
          simp only [concat, List.map_cons, List.foldr_cons, ByteArray.size_append]
          have := hne x₂ (by simp); omega
        have := step_split ad hI s hs c hr t₁ t d₁ (concat ((x₂ :: ds').map (·.2))) (hne (t₁, d₁) (by simp)) hrest room hrecv
        rw [hstep] at this
        simpa [concat] using this
      | _ => simp at h

end Server.Conn
