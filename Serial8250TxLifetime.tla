----------------------- MODULE Serial8250TxLifetime -----------------------
EXTENDS Integers, FiniteSets, TLC

\* A bounded, byte-position model of the generic 8250 TX cancellation path.
\* Kernel mapping and assumptions are in MODEL-NOTES.md. Provider steps are
\* separate from UART port-lock critical sections. No callback identity or
\* hardware-completion oracle is available to the UART callback.
CONSTANTS Capacity, MaxTransfers, MaxWrites, MaxFlushes,
          DrainCallbacks, AsyncStop, CheckRunning, CheckStatus,
          StatusInvokesCallback, AllowClose, AllowTerminateFailure
VARIABLE s
vars == <<s>>
Ids == 1..MaxTransfers
Cells == 0..(Capacity - 1)
LiveCallbacks == {"detached", "entered", "executed"}
Span(lo, len) == {(lo + n) % Capacity : n \in 0..(len - 1)}

EmptyDesc == [hw |-> "unused", cookie |-> FALSE, cb |-> "none",
              lo |-> 0, len |-> 0, image |-> [a \in Cells |-> 0]]
Init == s = [input |-> Capacity, output |-> 0, writes |-> 1, flushes |-> 0,
             mem |-> [a \in Cells |-> 1], next |-> 1, current |-> 0,
             size |-> 0, running |-> FALSE, terminating |-> FALSE,
             flushed |-> FALSE, blocked |-> FALSE, work |-> "idle",
             close |-> "open", freed |-> FALSE, deadlock |-> FALSE,
             desc |-> [i \in Ids |-> EmptyDesc]]

\* A completion or uart_write() can submit the next descriptor under the
\* SAME port lock. Only hardware execution is serialized by the provider;
\* several submitted descriptors can own storage in a broken execution.
CanStart(v) == /\ v.close = "open" /\ ~v.terminating /\ ~v.blocked
               /\ ~v.running /\ v.input > v.output
               /\ v.next <= MaxTransfers
Start(v) ==
    IF CanStart(v) THEN
       [v EXCEPT !.running = TRUE, !.flushed = FALSE,
                 !.size = v.input - v.output, !.current = v.next,
                 !.next = @ + 1,
                 !.desc[v.next] =
                    [hw |-> "active", cookie |-> FALSE, cb |-> "none",
                     lo |-> v.output, len |-> v.input - v.output,
                     image |-> v.mem]]
    ELSE v

Complete(v) ==
    Start([v EXCEPT !.running = FALSE,
                    !.output = IF v.flushed THEN @ ELSE @ + v.size,
                    !.blocked = IF v.flushed THEN FALSE ELSE @])

\* terminate_async can remove queued callbacks, but cannot recall a callback
\* already copied into a tasklet's private list/local variable.
Terminate(v) ==
    [v EXCEPT !.desc = [i \in Ids |->
        [v.desc[i] EXCEPT
          !.hw = CASE @ = "active" -> IF AsyncStop THEN "stopping" ELSE "stopped"
                   [] @ = "done" -> "stopped"
                   [] OTHER -> @,
          !.cb = IF @ = "queued" THEN "returned" ELSE @]]]

Drained(v) ==
    /\ \A i \in Ids : v.desc[i].hw \notin {"active", "stopping"}
    /\ \A i \in Ids : v.desc[i].cb \notin LiveCallbacks \cup {"queued"}

StartTx == /\ CanStart(s) /\ s' = Start(s)
Write(n) ==
    /\ s.close = "open" /\ ~s.blocked /\ ~s.freed
    /\ s.writes < MaxWrites /\ n \in 1..(Capacity - (s.input - s.output))
    /\ s' = Start([s EXCEPT !.input = @ + n, !.writes = @ + 1,
                    !.mem = [a \in Cells |->
                       IF a \in Span(s.input, n) THEN s.writes + 1 ELSE s.mem[a]]])

HardwareDone(i) ==
    /\ s.desc[i].hw = "active"
    \* Earlier descriptors execute first; queued != simultaneously running.
    /\ \A j \in 1..(i - 1) : s.desc[j].hw \notin {"active", "stopping"}
    /\ s' = [s EXCEPT !.desc[i].hw = "done"]
DmaIrq(i) ==
    /\ s.desc[i].hw = "done" /\ ~s.desc[i].cookie
    /\ s' = [s EXCEPT !.desc[i].cookie = TRUE, !.desc[i].cb = "queued"]
Capture(i) ==
    /\ s.desc[i].cb = "queued"
    /\ s' = [s EXCEPT !.desc[i].cb = "detached"]
Enter(i) ==
    /\ s.desc[i].cb = "detached"
    /\ s' = [s EXCEPT !.desc[i].cb = "entered"]
Invoke(i) ==
    /\ s.desc[i].cb = "entered" /\ ~s.freed
    /\ LET v == [s EXCEPT !.desc[i].cb = "executed"] IN
       s' = IF s.close # "open" \/ s.terminating \/ (CheckRunning /\ ~s.running)
            THEN v
            ELSE IF CheckStatus /\ s.current \in Ids
                 THEN IF StatusInvokesCallback /\ ~s.desc[s.current].cookie
                         /\ s.desc[s.current].hw = "done"
                      \* Old DW tx_status scans RAW.XFER, calls the NEW
                      \* descriptor's callback inline with port->lock held.
                      THEN [v EXCEPT !.deadlock = TRUE]
                      ELSE IF s.desc[s.current].cookie THEN Complete(v) ELSE v
                 ELSE Complete(v)
Return(i) ==
    /\ s.desc[i].cb = "executed"
    /\ s' = [s EXCEPT !.desc[i].cb = "returned"]
StopHardware(i) ==
    /\ s.desc[i].hw = "stopping"
    /\ s' = [s EXCEPT !.desc[i].hw = "stopped"]

Flush(ok) ==
    /\ s.close = "open" /\ s.flushes < MaxFlushes
    /\ ok \/ AllowTerminateFailure
    /\ LET v == [s EXCEPT !.input = 0, !.output = 0, !.flushes = @ + 1] IN
       s' = IF s.running /\ ~s.terminating
            THEN IF ok
                 THEN Terminate([v EXCEPT !.flushed = TRUE, !.blocked = TRUE,
                                          !.terminating = TRUE, !.work = "pending"])
                 ELSE [v EXCEPT !.flushed = TRUE, !.blocked = TRUE]
            ELSE v
WorkerBegin ==
    /\ s.work = "pending"
    /\ s' = [s EXCEPT !.work = "sync"]
WorkerSync ==
    /\ s.work = "sync" /\ (~DrainCallbacks \/ Drained(s))
    /\ s' = [s EXCEPT !.work = "ready"]
WorkerFinish ==
    /\ s.work = "ready"
    /\ LET v == [s EXCEPT !.work = "idle", !.terminating = FALSE, !.size = 0] IN
       s' = IF s.close = "open" THEN Complete(v) ELSE v

\* Unlike the original v7 model, close does NOT magically erase callbacks.
\* gate -> cancel_work_sync -> terminate -> synchronize -> unmap/free.
CloseGate ==
    /\ AllowClose /\ s.close = "open"
    /\ s' = [s EXCEPT !.close = "cancel"]
CloseCancel ==
    /\ s.close = "cancel" /\ s.work \in {"idle", "pending"}
    /\ s' = [s EXCEPT !.work = "idle", !.close = "terminate"]
CloseTerminate(ok) ==
    /\ s.close = "terminate" /\ (ok \/ AllowTerminateFailure)
    /\ s' = IF ok THEN Terminate([s EXCEPT !.close = "sync"])
                   \* release_dma() ignores terminate_sync's failure.
                   ELSE [s EXCEPT !.close = "free"]
CloseSync ==
    /\ s.close = "sync" /\ (~DrainCallbacks \/ Drained(s))
    /\ s' = [s EXCEPT !.close = "free"]
CloseFree ==
    /\ s.close = "free"
    /\ s' = [s EXCEPT !.close = "closed", !.freed = TRUE,
                      !.running = FALSE, !.terminating = FALSE, !.blocked = FALSE]

ProviderProgress(i) == HardwareDone(i) \/ DmaIrq(i) \/ Capture(i) \/ Enter(i)
                       \/ Invoke(i) \/ Return(i) \/ StopHardware(i)
WorkerProgress == WorkerBegin \/ WorkerSync \/ WorkerFinish
CloseProgress == CloseCancel \/ (\E ok \in BOOLEAN : CloseTerminate(ok))
                 \/ CloseSync \/ CloseFree
Next == /\ ~s.deadlock
        /\ \/ StartTx \/ (\E n \in 1..Capacity : Write(n))
           \/ (\E i \in Ids : ProviderProgress(i))
           \/ (\E ok \in BOOLEAN : Flush(ok))
           \/ WorkerProgress \/ CloseGate \/ CloseProgress

Spec == Init /\ [][Next]_vars
             /\ (\A i \in Ids : WF_vars(ProviderProgress(i)))
             /\ WF_vars(WorkerProgress) /\ WF_vars(CloseProgress)

TypeOK == /\ s.input \in Nat /\ s.output \in Nat
          /\ s.current \in 0..MaxTransfers /\ s.next \in 1..(MaxTransfers + 1)
          /\ s.mem \in [Cells -> 1..MaxWrites]
          /\ s.running \in BOOLEAN /\ s.blocked \in BOOLEAN
NoBufferAliasing == \A i \in Ids :
    s.desc[i].hw \in {"active", "stopping"} =>
       \A a \in Span(s.desc[i].lo, s.desc[i].len) : s.mem[a] = s.desc[i].image[a]
FifoAccounting == s.output <= s.input /\ s.input - s.output <= Capacity
NoUsersAtFree == ~s.freed \/ Drained(s)
NoCallbackReentry == ~s.deadlock
ReservationProgress == (s.blocked /\ s.close = "open") ~>
                        (~s.blocked \/ s.close # "open")
ShutdownProgress == (s.close # "open") ~> (s.close = "closed")
=============================================================================
