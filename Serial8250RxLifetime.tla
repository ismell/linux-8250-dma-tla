----------------------- MODULE Serial8250RxLifetime -----------------------
EXTENDS Integers, TLC

\* One finite generic 8250 RX transaction. Physical completion is deliberately
\* distinct from the provider's cookie/status. The consumer never tests count
\* or hw directly: those are provider state and the invariant's oracle only.
CONSTANTS Capacity, IdlePauseFails, AccurateResidue, DrainCallbacks,
          AsyncStop, AllowRecoveryFailure
VARIABLE s
vars == <<s>>
Init == s = [hw |-> "active", count |-> 0, cookie |-> FALSE,
             cb |-> "none", running |-> TRUE, terminating |-> FALSE,
             masked |-> FALSE, recover |-> FALSE, flushed |-> FALSE,
             work |-> "idle", delivered |-> 0, lost |-> FALSE]

ReportedCount(v) == IF v.cookie THEN Capacity
                   ELSE IF AccurateResidue THEN v.count ELSE 0
Drained(v) == /\ v.hw \notin {"active", "paused", "stopping"}
              /\ v.cb \notin {"queued", "detached", "entered", "executed"}
Terminate(v) ==
    [v EXCEPT !.hw = IF @ \in {"active", "paused"}
                    THEN IF AsyncStop THEN "stopping" ELSE "stopped"
                    ELSE "stopped",
              !.cb = IF @ = "queued" THEN "returned" ELSE @]

Receive == /\ s.hw = "active" /\ s.count < Capacity
           /\ s' = [s EXCEPT !.count = @ + 1,
                             !.hw = IF s.count + 1 = Capacity THEN "done" ELSE @]
Irq == /\ s.hw = "done" /\ ~s.cookie
       /\ s' = [s EXCEPT !.cookie = TRUE, !.cb = "queued"]
Capture == /\ s.cb = "queued" /\ s' = [s EXCEPT !.cb = "detached"]
Enter == /\ s.cb = "detached" /\ s' = [s EXCEPT !.cb = "entered"]
Invoke == /\ s.cb = "entered"
          /\ s' = IF ~s.terminating /\ s.running /\ s.cookie
                  THEN [s EXCEPT !.cb = "executed", !.running = FALSE,
                                  !.delivered = @ + ReportedCount(s)]
                  ELSE [s EXCEPT !.cb = "executed"]
Return == /\ s.cb = "executed" /\ s' = [s EXCEPT !.cb = "returned"]
StopHardware == /\ s.hw = "stopping" /\ s' = [s EXCEPT !.hw = "stopped"]

\* Pause + status + copy + terminate_async is one port-lock critical section.
\* IdlePauseFails describes a provider behavior to investigate, not proof
\* that any particular UART/platform exhibits it on hardware.
Flush ==
    /\ ~s.flushed /\ s.running /\ ~s.terminating
    /\ LET pauseFailed == IdlePauseFails /\ s.hw = "done"
           v == [s EXCEPT !.flushed = TRUE, !.terminating = TRUE,
                           !.work = "pending"] IN
       s' = IF pauseFailed /\ ~s.cookie
            THEN [v EXCEPT !.masked = TRUE, !.recover = TRUE]
            ELSE Terminate([v EXCEPT !.running = FALSE,
                                    !.delivered = @ + ReportedCount(s)])

BeginWorker(ok) ==
    /\ s.work = "pending" /\ (ok \/ AllowRecoveryFailure)
    /\ s' = IF ~s.recover THEN [s EXCEPT !.work = "sync"]
            ELSE IF ok
                 THEN Terminate([s EXCEPT !.work = "sync",
                      !.lost = s.hw = "done" /\ s.count = Capacity /\ s.delivered = 0])
                 \* The C worker retains ownership and leaves RX masked.
                 ELSE [s EXCEPT !.work = "failed"]
FinishWorker ==
    /\ s.work = "sync" /\ (~DrainCallbacks \/ Drained(s))
    /\ s' = [s EXCEPT !.work = "done", !.terminating = FALSE,
                      !.running = FALSE, !.masked = FALSE]

ProviderProgress == Receive \/ Irq \/ Capture \/ Enter \/ Invoke \/ Return \/ StopHardware
WorkerProgress == (\E ok \in BOOLEAN : BeginWorker(ok)) \/ FinishWorker
Next == ProviderProgress \/ Flush \/ WorkerProgress
Spec == Init /\ [][Next]_vars /\ WF_vars(ProviderProgress) /\ WF_vars(WorkerProgress)

TypeOK == /\ s.count \in 0..Capacity /\ s.delivered \in 0..(2 * Capacity)
          /\ s.running \in BOOLEAN /\ s.terminating \in BOOLEAN
NoDuplicateDelivery == s.delivered <= Capacity
NoCompletedRxDataLost == ~s.lost
NoPrematureReuse == (~s.running /\ ~s.terminating) =>
                    s.hw \notin {"active", "paused", "stopping"}
FailedRecoveryKeepsOwnership == s.work = "failed" =>
                                (s.running /\ s.terminating /\ s.masked)
WorkerProgressOrSafeFailure == s.work = "pending" ~> s.work \in {"done", "failed"}
=============================================================================
