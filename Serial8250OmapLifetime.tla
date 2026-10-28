---------------------- MODULE Serial8250OmapLifetime ----------------------
EXTENDS TLC
\* Narrow shutdown admission model, NOT the OMAP RX DMA implementation.
\* The completed descriptor's callback can survive the final RX flush.
CONSTANT EarlyGate
VARIABLE s
vars == <<s>>
Init == s = [phase |-> "open", shuttingDown |-> FALSE,
             callback |-> TRUE, rxRunning |-> TRUE, lateRestart |-> FALSE]

\* v8 holds port->lock across gate + final flush; callback takes that lock.
FinalFlush == /\ s.phase = "open"
              /\ s' = [s EXCEPT !.phase = "flushed", !.rxRunning = FALSE,
                                !.shuttingDown = EarlyGate]
Callback == /\ s.callback
            /\ s' = [s EXCEPT !.callback = FALSE,
                              !.rxRunning = IF s.shuttingDown THEN @ ELSE TRUE,
                              !.lateRestart = ~s.shuttingDown /\ s.phase # "open"]
ReleaseGate == /\ s.phase = "flushed"
               /\ s' = [s EXCEPT !.phase = "release", !.shuttingDown = TRUE]
Next == FinalFlush \/ Callback \/ ReleaseGate
Spec == Init /\ [][Next]_vars
NoRestartAfterFinalFlush == ~s.lateRestart
=============================================================================
