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

Deadlines (item ytzycm). Every phase but `querying` and `closed` runs under
one deadline (`Phase.deadline`), and the state numbers the period it runs in
(`State.gen`). The loop arms a monotonic timer for the deadline's budget when
it sees a new (deadline, generation) pair after a step, and reports the
timer's end as `expired`, with the pair it armed. An `expired` event that
names the current pair closes the connection, silently; any other changes
nothing (`step_expired_current`, `step_expired_stale`). A step starts a new
period, with a newer generation, unless it continues the current one
(`continues`, `step_gen`): bytes received do not extend the head or the body
deadline, and a partial send does not extend the write deadline. The loop
reports events in the order its callbacks run, an expiry included: an
expiry takes effect when it is reported, not at the instant its timer was
due, so a completion reported first is served even if that instant has
passed, and an expiry reported first closes the connection, after which the
completion of the operation in flight is discarded (the loop's assumption:
it reports nothing after `close`). The values of the budgets are the loop's
(`Server.Transport.Options`); this model only names them.

Effects precede their record: a receive or send has happened in the kernel
before its event reaches `step`, and a close is chosen before it is performed.
All of this state is volatile; nothing survives the process, so a crash
between an effect and its record can leave a peer with a prefix of a response
(possibly empty) and an unanswered request (README, "Production contract"). -/

namespace Server.Conn

/-- The deadlines that bound a connection; each is a budget the peer gets, and
its value is the loop's (`Server.Transport.Options`). -/
inductive Deadline where
  /-- Keep-alive: from the end of a response to the next request's first byte. -/
  | idle
  /-- A request's head: from accept for the first request, and for a later
  one from when the connection starts to read it. -/
  | head
  /-- A request's body: from the acceptance of its head. -/
  | body
  /-- A response: from when it is ready to the last byte handed to the socket. -/
  | write
deriving DecidableEq, Repr

/-- What a reading connection waits for. -/
inductive Read where
  /-- The next request, after a response, with nothing buffered. -/
  | idle
  /-- The rest of a request's head. -/
  | head
  /-- The rest of a body whose head was accepted; `continued` when
  `100 Continue` was sent for it. -/
  | body (continued : Bool)

/-- Whether `100 Continue` was sent for the request being read. -/
def Read.continued : Read → Bool
  | .body c => c
  | _ => false

/-- What a request that `needMore` still lacks leaves the connection waiting
for; `continued` when `100 Continue` was sent for it, which an adapter answers
only once the head is accepted. -/
def Read.of (continued : Bool) : Need → Read
  | .head => if continued then .body true else .head
  | .body => .body continued

/-- Where a connection goes once its current send is complete. -/
inductive Next where
  | close
  /-- Back to the buffered bytes; `continued` when the send was the interim
  `100 Continue` for the request at the buffer's start. -/
  | read (continued : Bool)

inductive Phase where
  /-- Waiting for bytes from the peer, for what `r` says. -/
  | reading (r : Read)
  /-- Sending `out` from offset `off`, then going on as `next` says. -/
  | writing (out : ByteArray) (off : Nat) (next : Next)
  /-- Waiting for the result of the query just asked for, then going on with
  `k`; the request is already consumed from `buf`, and no receive is in
  flight, so bytes the peer pipelines wait in the kernel. -/
  | querying (k : Query.Result → Await Dated)
  /-- The close action was issued; nothing more happens. -/
  | closed

/-- The deadline a phase runs under. The interim `100 Continue` is sent
under its request's body deadline, which starts when the head is accepted;
a query has none here (query deadlines are the database pool's). -/
def Phase.deadline : Phase → Option Deadline
  | .reading .idle => some .idle
  | .reading .head => some .head
  | .reading (.body _) => some .body
  | .writing _ _ (.read true) => some .body
  | .writing _ _ _ => some .write
  | .querying _ => none
  | .closed => none

structure State (σ : Type) where
  /-- Received bytes not yet consumed by a response. -/
  buf : ByteArray
  /-- What the adapter kept about the request at the start of `buf`
  (`Adapter.Fed`, `step_fed`). -/
  parser : σ
  phase : Phase
  /-- The generation of the deadline period the connection is in: the loop
  arms its timer for the pair (`phase.deadline`, `gen`), and an expiry naming
  another pair is stale. Unbounded; the loop keeps it as a Lean `Nat`. -/
  gen : Nat := 0

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
  /-- The timer the loop armed for deadline `d` in generation `g` ended. -/
  | expired (d : Deadline) (g : Nat)

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

/-- A new connection: reading the first request's head, whose deadline runs
from accept. -/
def initial : State σ := { buf := ByteArray.emptyWithCapacity inCap, parser := ad.init, phase := .reading .head }

def closeNow : State σ × Action := ({ buf := ByteArray.empty, parser := ad.init, phase := .closed }, .close)

/-- Waits for more bytes of the request at the start of `buf`, keeping the
adapter's state `p`, or closes when the buffer is full. -/
def wait (r : Read) (p : σ) (buf : ByteArray) : State σ × Action :=
  if buf.size < inCap then ({ buf, parser := p, phase := .reading r }, .recv (inCap - buf.size))
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
  | .needMore need => wait ad (Read.of continued need) (ad.handle p buf).1 buf
  | .continue interim =>
    if continued then wait ad (.body true) (ad.handle p buf).1 buf else startSend ad (ad.handle p buf).1 buf interim (.read true)
  | .respond consumed response =>
    if 0 < consumed ∧ consumed ≤ buf.size then resume ad now (buf.extract consumed buf.size) (.done response)
    else closeNow ad
  | .await consumed q k =>
    if 0 < consumed ∧ consumed ≤ buf.size then resume ad now (buf.extract consumed buf.size) (.query q k)
    else closeNow ad

/-- The answer to an event other than an expiry, before the generation is
set (`step`). -/
def advance (now : Nat) (s : State σ) (e : Event) : State σ × Action :=
  match s.phase, e with
  | .closed, _ => (s, .none)
  | _, .failed => closeNow ad
  | _, .refused => closeNow ad
  | .reading r, .received data =>
    if data.size = 0 then closeNow ad
    else if s.buf.size + data.size ≤ inCap then serve ad now r.continued s.parser (s.buf ++ data)
    else closeNow ad
  | .writing out off next, .sent n =>
    if n = 0 ∨ out.size < off + n then closeNow ad
    else if off + n < out.size then ({ s with phase := .writing out (off + n) next }, .send out (off + n))
    else match next with
      | .close => closeNow ad
      | .read continued =>
        if 0 < s.buf.size then serve ad now continued s.parser s.buf
        else ({ s with phase := .reading (if continued then .body true else .idle) }, .recv inCap)
  | .querying k, .answered r => resume ad now s.buf (k r)
  | _, _ => closeNow ad

/-- Whether event `e` leaves the connection in the deadline period it was in,
going from phase `p` to phase `p'`: more bytes of the same head or body (they
do not extend its deadline), more of the same send (a send is resumed only
at a nonzero offset, `step_sent_partial`), or the end of the interim
`100 Continue`, after which the body it asked for is read under the same body
deadline. An interim response started while a body is read (an adapter that
asks for the body before it answers the expectation) is written under that
body's deadline too. Anything else starts a new period. -/
def continues : Phase → Event → Phase → Bool
  | .reading .head, .received _, .reading .head => true
  | .reading (.body _), .received _, .reading (.body _) => true
  | .reading (.body _), .received _, .writing _ _ (.read true) => true
  | .writing _ _ _, .sent _, .writing _ off _ => off != 0
  | .writing _ _ (.read true), .sent _, .reading (.body _) => true
  | _, _, _ => false

/-- Sets the generation of `r`, the answer to `e` in state `s`: kept while the
period continues, the next one otherwise; a closed connection keeps none. -/
def stamp (s : State σ) (e : Event) (r : State σ × Action) : State σ × Action :=
  match r.1.phase with
  | .closed => r
  | p => ({ r.1 with gen := if continues s.phase e p then s.gen else s.gen + 1 }, r.2)

/-- The connection's answer to event `e`, reported at wall clock `now` (Unix
seconds), which only a response sent in answer to it sees (`Dated`). An
expiry of the current deadline period closes the connection, and any other
expiry changes nothing. -/
def step (now : Nat) (s : State σ) (e : Event) : State σ × Action :=
  match s.phase, e with
  | .closed, _ => (s, .none)
  | p, .expired d g => if p.deadline = some d ∧ s.gen = g then closeNow ad else (s, .none)
  | _, _ => stamp s e (advance ad now s e)

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

theorem wait_inv (c : Read) (p : σ) (buf : ByteArray) : Inv (wait ad c p buf).1 := by
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
theorem advance_inv (s : State σ) (e : Event) (hs : Inv s) : Inv (advance ad now s e).1 := by
  obtain ⟨hb, hw⟩ := hs
  unfold advance
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
theorem advance_closed (s : State σ) (e : Event) (h : s.phase = .closed) :
    advance ad now s e = (s, .none) := by
  unfold advance; rw [h]

/-- A declined receive always closes the connection. -/
theorem advance_refused (s : State σ) (h : s.phase ≠ .closed) :
    advance ad now s .refused = closeNow ad := by
  unfold advance; split <;> simp_all

theorem wait_close (c : Read) (p : σ) (buf : ByteArray) :
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
theorem advance_close (s : State σ) (e : Event) :
    (advance ad now s e).2 = .close → (advance ad now s e).1.phase = .closed := by
  unfold advance
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

theorem wait_recv (c : Read) (p : σ) (buf : ByteArray) (room : Nat) :
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
theorem advance_recv (s : State σ) (e : Event) (room : Nat) :
    (advance ad now s e).2 = .recv room →
      0 < room ∧ (advance ad now s e).1.buf.size + room = inCap := by
  unfold advance
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
theorem advance_send (s : State σ) (e : Event) (data : ByteArray) (off : Nat) :
    (advance ad now s e).2 = .send data off → off < data.size := by
  unfold advance
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
theorem advance_query (s : State σ) (e : Event) (q : Query) :
    (advance ad now s e).2 = .query q → ∃ k, (advance ad now s e).1.phase = .querying k := by
  unfold advance
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

theorem wait_fed (c : Read) (p : σ) (buf : ByteArray) (h : ad.Fed p buf) : FedInv ad (wait ad c p buf).1 := by
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
theorem advance_fed (s : State σ) (e : Event) (hs : FedInv ad s) : FedInv ad (advance ad now s e).1 := by
  unfold advance
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

/-! ## From `advance` to `step`

`step` answers every event other than an expiry as `advance` does, apart from
the generation (`step_obs`); an expiry either closes the connection or changes
nothing (`step_expiry`). So each guarantee proved above for `advance` holds
for `step` as stated below. -/

/-- What a step decides, apart from the generation. -/
def obs (r : State σ × Action) : ByteArray × σ × Phase × Action := (r.1.buf, r.1.parser, r.1.phase, r.2)

/-- Whether an event is an expiry. -/
def Event.isExpiry : Event → Bool
  | .expired .. => true
  | _ => false

theorem stamp_obs (s : State σ) (e : Event) (r : State σ × Action) : obs (stamp s e r) = obs r := by
  unfold stamp; split <;> rfl

/-- An event other than an expiry is answered as `advance` answers it, apart
from the generation. -/
theorem step_obs (s : State σ) (e : Event) (he : e.isExpiry = false) :
    obs (step ad now s e) = obs (advance ad now s e) := by
  unfold step
  split
  · rename_i h; simp [advance, h]
  · simp [Event.isExpiry] at he
  · exact stamp_obs _ _ _

/-- An expiry closes the connection or changes nothing. -/
theorem step_expiry (s : State σ) (d : Deadline) (g : Nat) :
    step ad now s (.expired d g) = (s, .none) ∨ step ad now s (.expired d g) = closeNow ad := by
  unfold step
  split
  · exact .inl rfl
  · split
    · exact .inr rfl
    · exact .inl rfl
  · rename_i h; exact absurd rfl (h _ _)

/-- `advance` reads of the state only its buffer, the adapter's state and
the phase. -/
theorem advance_congr (s s' : State σ) (e : Event) (hb : s.buf = s'.buf) (hp : s.parser = s'.parser)
    (hph : s.phase = s'.phase) : obs (advance ad now s e) = obs (advance ad now s' e) := by
  obtain ⟨b, p, ph, g⟩ := s
  obtain ⟨b', p', ph', g'⟩ := s'
  simp only at hb hp hph
  subst hb hp hph
  cases ph <;> cases e <;> simp only [advance] <;> (repeat' split) <;> simp_all [obs]

theorem step_inv (s : State σ) (e : Event) (hs : Inv s) : Inv (step ad now s e).1 := by
  cases he : e.isExpiry
  · have h := step_obs ad now s e he
    simp only [obs, Prod.mk.injEq] at h
    obtain ⟨hb, -, hph, -⟩ := h
    have := advance_inv ad now s e hs
    unfold Inv at this ⊢; rw [hb, hph]; exact this
  · cases e <;> simp [Event.isExpiry] at he
    rcases step_expiry ad now s _ _ with h | h <;> rw [h]
    · exact hs
    · exact closeNow_inv ad

/-- A closed connection stays closed and asks for nothing. -/
theorem step_closed (s : State σ) (e : Event) (h : s.phase = .closed) :
    step ad now s e = (s, .none) := by
  unfold step; split
  · rfl
  · rename_i h'; simp [h] at h'
  · rename_i h'; simp [h] at h'

/-- A declined receive always closes the connection. -/
theorem step_refused (s : State σ) (h : s.phase ≠ .closed) :
    step ad now s .refused = closeNow ad := by
  unfold step; split
  · contradiction
  · contradiction
  · rw [advance_refused ad now s h]; rfl

/-- The close action always leaves the connection closed, so nothing follows it. -/
theorem step_close (s : State σ) (e : Event) :
    (step ad now s e).2 = .close → (step ad now s e).1.phase = .closed := by
  cases he : e.isExpiry
  · have h := step_obs ad now s e he
    simp only [obs, Prod.mk.injEq] at h
    obtain ⟨-, -, hph, ha⟩ := h
    rw [hph, ha]; exact advance_close ad now s e
  · cases e <;> simp [Event.isExpiry] at he
    rcases step_expiry ad now s _ _ with h | h <;> rw [h]
    · simp
    · simp [closeNow]

/-- A receive always has room, and never more than the buffer can take. -/
theorem step_recv (s : State σ) (e : Event) (room : Nat) :
    (step ad now s e).2 = .recv room →
      0 < room ∧ (step ad now s e).1.buf.size + room = inCap := by
  cases he : e.isExpiry
  · have h := step_obs ad now s e he
    simp only [obs, Prod.mk.injEq] at h
    obtain ⟨hb, -, -, ha⟩ := h
    rw [hb, ha]; exact advance_recv ad now s e room
  · cases e <;> simp [Event.isExpiry] at he
    rcases step_expiry ad now s _ _ with h | h <;> rw [h]
    · simp
    · simp [closeNow]

/-- Every send starts inside its data, so it has at least one byte to write. -/
theorem step_send (s : State σ) (e : Event) (data : ByteArray) (off : Nat) :
    (step ad now s e).2 = .send data off → off < data.size := by
  cases he : e.isExpiry
  · have h := step_obs ad now s e he
    simp only [obs, Prod.mk.injEq] at h
    obtain ⟨-, -, -, ha⟩ := h
    rw [ha]; exact advance_send ad now s e data off
  · cases e <;> simp [Event.isExpiry] at he
    rcases step_expiry ad now s _ _ with h | h <;> rw [h]
    · simp
    · simp [closeNow]

/-- A query is asked for only together with the phase that waits for its
result. So, provided the loop answers each `query` action with exactly one
`answered` event and reports nothing else meanwhile (the assumption in this
file's header, which the loop checks at run time, `serve.zig` `answered`; a
`querying` phase has no deadline, so every expiry reported meanwhile is stale
and changes nothing), a connection has at most one query outstanding and
that event finds its continuation. -/
theorem step_query (s : State σ) (e : Event) (q : Query) :
    (step ad now s e).2 = .query q → ∃ k, (step ad now s e).1.phase = .querying k := by
  cases he : e.isExpiry
  · have h := step_obs ad now s e he
    simp only [obs, Prod.mk.injEq] at h
    obtain ⟨-, -, hph, ha⟩ := h
    rw [hph, ha]; exact advance_query ad now s e q
  · cases e <;> simp [Event.isExpiry] at he
    rcases step_expiry ad now s _ _ with h | h <;> rw [h]
    · simp
    · simp [closeNow]

/-- Every step keeps the adapter's state fed for the buffer. -/
theorem step_fed (s : State σ) (e : Event) (hs : FedInv ad s) : FedInv ad (step ad now s e).1 := by
  cases he : e.isExpiry
  · have h := step_obs ad now s e he
    simp only [obs, Prod.mk.injEq] at h
    obtain ⟨hb, hp, -, -⟩ := h
    have := advance_fed ad now s e hs
    unfold FedInv at this ⊢; rw [hb, hp]; exact this
  · cases e <;> simp [Event.isExpiry] at he
    rcases step_expiry ad now s _ _ with h | h <;> rw [h]
    · exact hs
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

theorem view_of_obs {r r' : State σ × Action} (h : obs r = obs r') : view r = view r' := by
  simp only [obs, Prod.mk.injEq] at h
  obtain ⟨hb, -, hph, ha⟩ := h
  simp [view, hb, hph, ha]

theorem wait_view (c : Read) (p p' : σ) (buf : ByteArray) : view (wait ad c p buf) = view (wait ad c p' buf) := by
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

@[simp] theorem Read.of_continued (c : Bool) (n : Need) : (Read.of c n).continued = c := by
  cases n <;> cases c <;> rfl

theorem advance_received_recv (s : State σ) (c : Read) (hr : s.phase = .reading c) (d : ByteArray) (room : Nat)
    (h : (advance ad now s (.received d)).2 = .recv room) :
    (advance ad now s (.received d)).1.buf = s.buf ++ d ∧
      ∃ c', (advance ad now s (.received d)).1.phase = .reading c' ∧ c'.continued = c.continued := by
  revert h
  unfold advance
  rw [hr]
  simp only
  split
  · simp [closeNow]
  · split
    · unfold serve
      split
      · unfold wait; split <;> simp [closeNow]
      · split
        · rename_i hc; rw [hc]; unfold wait; split <;> simp [closeNow, Read.continued]
        · intro h; exact absurd h (startSend_recv ad _ _ _ _ _)
      · split
        · intro h; exact absurd h (resume_recv ad now _ _ _)
        · simp [closeNow]
      · split
        · intro h; exact absurd h (resume_recv ad now _ _ _)
        · simp [closeNow]
    · simp [closeNow]

/-- A receive answered with another receive leaves the connection reading
the same request (whether `100 Continue` was sent for it unchanged), with the
received bytes appended to its buffer. -/
theorem step_received_recv (s : State σ) (c : Read) (hr : s.phase = .reading c) (d : ByteArray) (room : Nat)
    (h : (step ad now s (.received d)).2 = .recv room) :
    (step ad now s (.received d)).1.buf = s.buf ++ d ∧
      ∃ c', (step ad now s (.received d)).1.phase = .reading c' ∧ c'.continued = c.continued := by
  have ho := step_obs ad now s (.received d) rfl
  simp only [obs, Prod.mk.injEq] at ho
  obtain ⟨hb, -, hph, ha⟩ := ho
  rw [ha] at h; rw [hb, hph]
  exact advance_received_recv ad now s c hr d room h

theorem advance_split (hI : ad.Incremental) (s : State σ) (hs : FedInv ad s) (c : Read) (hr : s.phase = .reading c)
    (t₁ t₂ : Nat) (d₁ d₂ : ByteArray) (h₁ : 0 < d₁.size) (h₂ : 0 < d₂.size) (room : Nat)
    (hrecv : (advance ad t₁ s (.received d₁)).2 = .recv room) :
    view (advance ad t₂ (advance ad t₁ s (.received d₁)).1 (.received d₂)) = view (advance ad t₂ s (.received (d₁ ++ d₂))) := by
  obtain ⟨hb, c', hp, hc⟩ := advance_received_recv ad t₁ s c hr d₁ room hrecv
  have hf := advance_fed ad t₁ s (.received d₁) hs
  generalize advance ad t₁ s (.received d₁) = r at hb hp hf
  obtain ⟨⟨buf, p, phase, g⟩, a⟩ := r
  simp only at hb hp hf
  subst hb hp
  unfold advance
  rw [hr]
  simp only [ByteArray.size_append]
  have n₁ : ¬ d₂.size = 0 := by omega
  have n₂ : ¬ d₁.size + d₂.size = 0 := by omega
  simp only [n₁, n₂, ite_false, ← Nat.add_assoc, hc]
  split
  · rw [ByteArray.append_assoc]
    have hp' : ad.Fed p (s.buf ++ (d₁ ++ d₂)) := by
      have := hf.extend ad d₂; simpa [ByteArray.append_assoc] using this
    exact serve_congr ad t₂ hI _ _ _ _ hp' (hs.extend ad (d₁ ++ d₂))
  · rfl

/-- Receiving `d₁` at `t₁` and then `d₂` at `t₂` ends as receiving `d₁ ++ d₂`
at once at `t₂`, when the first receive was answered with another receive. -/
theorem step_split (hI : ad.Incremental) (s : State σ) (hs : FedInv ad s) (c : Read) (hr : s.phase = .reading c)
    (t₁ t₂ : Nat) (d₁ d₂ : ByteArray) (h₁ : 0 < d₁.size) (h₂ : 0 < d₂.size) (room : Nat)
    (hrecv : (step ad t₁ s (.received d₁)).2 = .recv room) :
    view (step ad t₂ (step ad t₁ s (.received d₁)).1 (.received d₂)) = view (step ad t₂ s (.received (d₁ ++ d₂))) := by
  have o₁ := step_obs ad t₁ s (.received d₁) rfl
  have o₂ := step_obs ad t₂ (step ad t₁ s (.received d₁)).1 (.received d₂) rfl
  have o₃ := step_obs ad t₂ s (.received (d₁ ++ d₂)) rfl
  simp only [obs, Prod.mk.injEq] at o₁
  obtain ⟨hb, hp, hph, ha⟩ := o₁
  have o₄ := advance_congr ad t₂ (step ad t₁ s (.received d₁)).1 (advance ad t₁ s (.received d₁)).1 (.received d₂) hb hp hph
  rw [ha] at hrecv
  rw [view_of_obs o₂, view_of_obs o₄, view_of_obs o₃]
  exact advance_split ad hI s hs c hr t₁ t₂ d₁ d₂ h₁ h₂ room hrecv

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
    ∀ (s : State σ), FedInv ad s → ∀ (c : Read), s.phase = .reading c →
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
        obtain ⟨-, c', hp, -⟩ := step_received_recv ad t₁ s c hr d₁ room hrecv
        have hf := step_fed ad t₁ s (.received d₁) hs
        rw [hstep] at hp hf
        have hne' : ∀ x ∈ x₂ :: ds', 0 < x.2.size := fun x hx => hne x (List.mem_cons_of_mem _ hx)
        rw [List.getLast?_cons_cons] at hl
        rw [ih hne' s' hf c' hp r t d h hl]
        have hrest : 0 < (concat ((x₂ :: ds').map (·.2))).size := by
          simp only [concat, List.map_cons, List.foldr_cons, ByteArray.size_append]
          have := hne x₂ (by simp); omega
        have := step_split ad hI s hs c hr t₁ t d₁ (concat ((x₂ :: ds').map (·.2))) (hne (t₁, d₁) (by simp)) hrest room hrecv
        rw [hstep] at this
        simpa [concat] using this
      | _ => simp at h

/-! ## Deadlines

The contract of `Event.expired` (item ytzycm): an expiry of the current
period closes the connection, any other changes nothing, a closed connection
stays closed and asks for nothing more, so no request is dispatched and no
byte is sent after an expiry, and a connection asks for its close at most
once. A step that does not continue the period gives it a newer generation,
and generations never decrease while the connection is open, so an expiry
the loop armed for an earlier period never closes it. -/

/-- An expiry that names another deadline or generation than the current one
changes nothing and asks for nothing. -/
theorem step_expired_stale (s : State σ) (d : Deadline) (g : Nat)
    (h : ¬ (s.phase.deadline = some d ∧ s.gen = g)) : step ad now s (.expired d g) = (s, .none) := by
  unfold step; split
  · rfl
  · next heq _ => cases heq; simp [h]
  · rename_i h'; exact absurd rfl (h' _ _)

/-- An expiry of the current deadline period closes the connection. -/
theorem step_expired_current (s : State σ) (d : Deadline) (g : Nat)
    (h : s.phase.deadline = some d) (hg : s.gen = g) : step ad now s (.expired d g) = closeNow ad := by
  unfold step; split
  · rename_i hc; rw [hc] at h; simp [Phase.deadline] at h
  · next heq _ => cases heq; simp [h, hg]
  · rename_i h'; exact absurd rfl (h' _ _)

/-- The actions answered to the events `es`, in order. -/
def actions (s : State σ) : List (Nat × Event) → List Action
  | [] => []
  | (t, e) :: es => (step ad t s e).2 :: actions (step ad t s e).1 es

/-- A closed connection stays as it is, whatever events follow, and answers
each of them with nothing. -/
theorem run_closed (s : State σ) (h : s.phase = .closed) :
    ∀ es, run ad s es = s ∧ ∀ a ∈ actions ad s es, a = .none := by
  intro es
  induction es with
  | nil => simp [run, actions]
  | cons x es ih =>
    obtain ⟨t, e⟩ := x
    have hs := step_closed ad t s e h
    simp only [run, actions, hs, List.mem_cons]
    exact ⟨ih.1, fun a ha => ha.elim id (ih.2 a)⟩

/-- After an expiry of the current period, in any phase (reading a head or a
body, writing a response, or idle), the connection asks for its close and
then for nothing: no request is dispatched, no query asked for and no byte
sent, whatever events the loop still reports (the completion of an operation
that was in flight included). -/
theorem expired_then_nothing (s : State σ) (d : Deadline) (g : Nat)
    (h : s.phase.deadline = some d) (hg : s.gen = g) (es : List (Nat × Event)) :
    (step ad now s (.expired d g)).2 = .close ∧ ∀ a ∈ actions ad (step ad now s (.expired d g)).1 es, a = .none := by
  rw [step_expired_current ad now s d g h hg]
  exact ⟨rfl, (run_closed ad (closeNow ad).1 rfl es).2⟩

/-- Whether an action is the close. -/
def Action.isClose : Action → Bool
  | .close => true
  | _ => false

/-- A connection asks for its close at most once, whatever events are
reported, so the loop releases its socket and its slot once. -/
theorem close_once (s : State σ) (es : List (Nat × Event)) :
    ((actions ad s es).filter Action.isClose).length ≤ 1 := by
  induction es generalizing s with
  | nil => simp [actions]
  | cons x es ih =>
    obtain ⟨t, e⟩ := x
    simp only [actions, List.filter_cons]
    cases hc : (step ad t s e).2.isClose
    · simpa using ih _
    · have hclose : (step ad t s e).2 = .close := by
        revert hc; cases (step ad t s e).2 <;> simp [Action.isClose]
      have hcl := step_close ad t s e hclose
      have hn := (run_closed ad _ hcl es).2
      have : (actions ad (step ad t s e).1 es).filter Action.isClose = [] := by
        rw [List.filter_eq_nil_iff]; intro a ha; simp [hn a ha, Action.isClose]
      simp [this]

/-- The generation after an event other than an expiry, while the connection
stays open: kept when the event continues the deadline period, the next one
otherwise. -/
theorem step_gen (s : State σ) (e : Event) (he : e.isExpiry = false)
    (hc : (step ad now s e).1.phase ≠ .closed) :
    (step ad now s e).1.gen = if continues s.phase e (step ad now s e).1.phase then s.gen else s.gen + 1 := by
  revert hc
  unfold step
  split
  · rename_i h; intro hc; exact absurd h hc
  · simp [Event.isExpiry] at he
  · unfold stamp
    split
    · rename_i h; intro hc; exact absurd h hc
    · intro _; rfl

/-- Generations never decrease while the connection is open. -/
theorem step_gen_le (s : State σ) (e : Event) (hc : (step ad now s e).1.phase ≠ .closed) :
    s.gen ≤ (step ad now s e).1.gen := by
  cases he : e.isExpiry
  · rw [step_gen ad now s e he hc]; split <;> omega
  · cases e <;> simp [Event.isExpiry] at he
    rcases step_expiry ad now s _ _ with h | h <;> rw [h] at hc ⊢
    · exact Nat.le_refl _
    · exact absurd rfl hc

theorem run_gen_le (es : List (Nat × Event)) :
    ∀ (s : State σ), (run ad s es).phase ≠ .closed → s.gen ≤ (run ad s es).gen := by
  induction es with
  | nil => intro s _; exact Nat.le_refl _
  | cons x es ih =>
    obtain ⟨t, e⟩ := x
    intro s hc
    simp only [run] at hc ⊢
    have hs : (step ad t s e).1.phase ≠ .closed := by
      intro hcl; rw [(run_closed ad _ hcl es).1] at hc; exact hc hcl
    exact Nat.le_trans (step_gen_le ad t s e hs) (ih _ hc)

/-- A phase change invalidates older generations: an expiry the loop armed
for a generation older than the current one changes nothing, now or after
any further events. -/
theorem expired_old_stale (s : State σ) (d : Deadline) (g : Nat) (hg : g < s.gen) (es : List (Nat × Event)) :
    step ad now (run ad s es) (.expired d g) = (run ad s es, .none) := by
  by_cases hc : (run ad s es).phase = .closed
  · exact step_closed ad now _ _ hc
  · apply step_expired_stale
    intro ⟨_, h⟩
    have := run_gen_le ad es s hc
    omega

/-- Bytes received do not extend the head or the body deadline: a receive
that leaves the connection reading the same part of the request keeps the
generation, so the timer armed for it keeps running. -/
theorem step_received_keeps (s : State σ) (d : ByteArray) (r r' : Read)
    (hr : s.phase = .reading r) (hr' : (step ad now s (.received d)).1.phase = .reading r')
    (hk : (Phase.reading r).deadline = (Phase.reading r').deadline) (hi : r ≠ .idle) :
    (step ad now s (.received d)).1.gen = s.gen := by
  rw [step_gen ad now s _ rfl (by rw [hr']; simp), hr, hr']
  cases r <;> cases r' <;> simp_all [continues, Phase.deadline]

theorem wait_writing (c : Read) (p : σ) (buf out : ByteArray) (off : Nat) (next : Next) :
    (wait ad c p buf).1.phase ≠ .writing out off next := by
  unfold wait; split <;> simp [closeNow]

theorem startSend_writing (p : σ) (buf out o : ByteArray) (n next : Next) (off : Nat)
    (h : (startSend ad p buf o n).1.phase = .writing out off next) : off = 0 := by
  revert h; unfold startSend; split <;> simp [closeNow]; intro _ h _; exact h.symm

theorem serve_writing (c : Bool) (p : σ) (buf out : ByteArray) (off : Nat) (next : Next)
    (h : (serve ad now c p buf).1.phase = .writing out off next) : off = 0 := by
  revert h
  unfold serve
  split
  · intro h; exact absurd h (wait_writing ad _ _ _ _ _ _)
  · split
    · intro h; exact absurd h (wait_writing ad _ _ _ _ _ _)
    · exact startSend_writing ad _ _ _ _ _ _ _
  · split
    · simp only [resume]; exact startSend_writing ad _ _ _ _ _ _ _
    · simp [closeNow]
  · split
    · simp [resume]
    · simp [closeNow]

/-- A send is resumed only at a nonzero offset, and then it is the rest of
the same response: so `continues`, which keeps the write deadline for a
writing phase at a nonzero offset, keeps it exactly for the same response. -/
theorem step_sent_partial (s : State σ) (out : ByteArray) (off : Nat) (next : Next) (n : Nat)
    (hw : s.phase = .writing out off next) (out' : ByteArray) (off' : Nat) (next' : Next)
    (h : (step ad now s (.sent n)).1.phase = .writing out' off' next') (h0 : off' ≠ 0) :
    out' = out ∧ off' = off + n ∧ next' = next := by
  have ho := step_obs ad now s (.sent n) rfl
  simp only [obs, Prod.mk.injEq] at ho
  rw [ho.2.2.1] at h
  revert h
  unfold advance
  rw [hw]
  simp only
  split
  · simp [closeNow]
  · split
    · simp only [Phase.writing.injEq]; intro ⟨a, b, c⟩; exact ⟨a.symm, b.symm, c.symm⟩
    · split
      · simp [closeNow]
      · split
        · intro h; exact absurd (serve_writing ad now _ _ _ _ _ _ h) h0
        · simp

end Server.Conn
