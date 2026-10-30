----------------------- MODULE Serial8250RxDmaV8 -----------------------
EXTENDS Integers, TLC

(***************************************************************************)
(* Formal TLA+ Model of Linux 8250 UART RX DMA Cancellation & Pause Retry  *)
(* in [PATCH v8 5/6] ("serial: 8250: retire canceled RX DMA before reusing *)
(* the receive buffer", commit 2f1127ac7473) and drivers/tty/serial/8250/: *)
(*   - 8250_dma.c: serial8250_rx_dma_try_flush(), dma_rx_complete(),       *)
(*                 serial8250_rx_dma_flush_work(), serial8250_rx_dma_flush *)
(*   - 8250_port.c: serial8250_out_IER(), handle_rx_dma()                  *)
(*   - 8250_dw.c: dw8250_idle_enter(), dw8250_set_divisor()                *)
(*                                                                         *)
(* Key v8 state machine addition:                                          *)
(*   - dma->rx_pause_pending: set in serial8250_rx_dma_try_flush() when    *)
(*     dmaengine_pause() returns non-zero and dmaengine_tx_status() !=     *)
(*     DMA_COMPLETE. Masks UART_IER_RLSI | UART_IER_RDI | UART_IER_RTOIE   *)
(*     via serial8250_out_IER() and retries serial8250_rx_dma_try_flush()  *)
(*     inside serial8250_rx_dma_flush_work() in an unbounded for (;;) loop *)
(*     with usleep_range(1000, 2000).                                      *)
(***************************************************************************)

CONSTANTS
    RxSize,                     \* DMA buffer capacity (e.g., 2 bytes)
    MaxFlushes,                 \* Bound on UART RX timeout flushes
    MaxWorkerRetries,           \* Bound for detecting unbounded pause-retry loops
    PauseFailsWhenHwCompleted,  \* TRUE if dmaengine_pause() fails after HW finished
    PauseFailsWhenHwActive,     \* TRUE if dmaengine_pause() fails on active transfer
    PauseSucceedsOnRetry,       \* TRUE if a retry of dmaengine_pause() can succeed
    BoundPauseRetries,          \* FALSE in v8; TRUE in proposed fix (escalate to recover)
    AccurateResidueWhenPaused,  \* TRUE if paused residue reflects received bytes
    DrainCallbacksOnSync,       \* TRUE if dmaengine_synchronize() drains callbacks
    AsyncHardwareStop,          \* TRUE if terminate_async stops HW asynchronously
    AllowDmaError,              \* TRUE if DMA provider can report DMA_ERROR
    AllowTerminateFailure,      \* TRUE if terminate_async / terminate_sync can fail
    AllowClose,                 \* TRUE if port shutdown is modeled
    AllowDwSetDivisor           \* TRUE if dw8250_set_divisor() is modeled

VARIABLES
    hw_state,           \* "idle", "active", "paused", "completed", "stopping"
    hw_bytes,           \* 0..RxSize: bytes written by DMA into dma->rx_buf
    peer_done,          \* TRUE if remote transmitter stopped sending after < RxSize
    cookie_status,      \* "NONE", "IN_PROGRESS", "COMPLETE", "ERROR"
    cb_state,           \* "none", "queued", "detached", "entered"
    rx_running,         \* dma->rx_running (BOOLEAN)
    rx_terminating,     \* dma->rx_terminating (BOOLEAN)
    rx_pause_pending,   \* dma->rx_pause_pending (BOOLEAN) -- NEW in v8 Patch 5/6
    rx_err,             \* dma->rx_err (BOOLEAN)
    ier_rx_enabled,     \* software shadow (p->ier & (UART_IER_RLSI | UART_IER_RDI))
    hw_ier_rx_enabled,  \* hardware UART_IER RX interrupt enable state
    work_state,         \* "idle", "queued", "loop", "sleeping", "sync", "recover", "post_sync"
    worker_retries,     \* number of usleep_range(1000, 2000) retries in flush_work
    shutting_down,      \* dma->shutting_down (BOOLEAN)
    flushes,            \* count of UART RX timeout flush invocations
    delivered,          \* total bytes delivered to TTY flip buffer
    completed_lost,     \* TRUE if a full completed RxSize transfer was discarded
    dw_divisor_aborted  \* TRUE if dw8250_set_divisor() aborted due to rx_dma_flush error

vars == <<hw_state, hw_bytes, peer_done, cookie_status, cb_state,
          rx_running, rx_terminating, rx_pause_pending, rx_err,
          ier_rx_enabled, hw_ier_rx_enabled, work_state, worker_retries,
          shutting_down, flushes, delivered, completed_lost, dw_divisor_aborted>>

-----------------------------------------------------------------------------
(* Helpers corresponding to 8250_port.c and 8250_dma.c *)

\* 8250.h:162: serial8250_rx_dma_recovering(up)
RxDmaRecovering(pause_pending, err, terminating) ==
    pause_pending \/ (err /\ terminating)

\* 8250.h:167-178: serial8250_out_IER(up, ier)
ComputeHwIer(ier_shadow, pause_pending, err, terminating) ==
    IF RxDmaRecovering(pause_pending, err, terminating)
    THEN FALSE
    ELSE ier_shadow

\* 8250_dma.c:95: count = dma->rx_size - state->residue
ReportedCount ==
    IF cookie_status = "COMPLETE" THEN RxSize
    ELSE IF AccurateResidueWhenPaused THEN hw_bytes
    ELSE 0

\* Provider callback and hardware quiescence check for dmaengine_synchronize()
ProviderDrained ==
    /\ hw_state \notin {"active", "paused", "stopping"}
    /\ cb_state \notin {"queued", "detached", "entered"}

-----------------------------------------------------------------------------
(* Initial State: One active RX DMA transfer started by serial8250_rx_dma() *)

Init ==
    /\ hw_state = "active"
    /\ hw_bytes = 0
    /\ peer_done = FALSE
    /\ cookie_status = "IN_PROGRESS"
    /\ cb_state = "none"
    /\ rx_running = TRUE
    /\ rx_terminating = FALSE
    /\ rx_pause_pending = FALSE
    /\ rx_err = FALSE
    /\ ier_rx_enabled = TRUE
    /\ hw_ier_rx_enabled = TRUE
    /\ work_state = "idle"
    /\ worker_retries = 0
    /\ shutting_down = FALSE
    /\ flushes = 0
    /\ delivered = 0
    /\ completed_lost = FALSE
    /\ dw_divisor_aborted = FALSE

-----------------------------------------------------------------------------
(* Wire / Hardware DMA Engine Actions *)

\* UART receives a byte into the active DMA transfer
ReceiveByte ==
    /\ hw_state = "active"
    /\ ~peer_done
    /\ hw_bytes < RxSize
    /\ hw_bytes' = hw_bytes + 1
    /\ hw_state' = IF hw_bytes + 1 = RxSize THEN "completed" ELSE "active"
    /\ UNCHANGED <<peer_done, cookie_status, cb_state, rx_running, rx_terminating,
                   rx_pause_pending, rx_err, ier_rx_enabled, hw_ier_rx_enabled,
                   work_state, worker_retries, shutting_down, flushes,
                   delivered, completed_lost, dw_divisor_aborted>>

\* Remote peer finishes sending a partial burst (< RxSize bytes) and goes idle,
\* which causes the UART hardware to raise UART_IIR_RX_TIMEOUT.
PeerStopAfterPartialBurst ==
    /\ hw_state = "active"
    /\ hw_bytes > 0
    /\ hw_bytes < RxSize
    /\ ~peer_done
    /\ peer_done' = TRUE
    /\ UNCHANGED <<hw_state, hw_bytes, cookie_status, cb_state, rx_running,
                   rx_terminating, rx_pause_pending, rx_err, ier_rx_enabled,
                   hw_ier_rx_enabled, work_state, worker_retries, shutting_down,
                   flushes, delivered, completed_lost, dw_divisor_aborted>>

\* DMA controller interrupt handler publishes DMA_COMPLETE and queues callback
DmaIrq ==
    /\ hw_state = "completed"
    /\ cookie_status = "IN_PROGRESS"
    /\ cookie_status' = "COMPLETE"
    /\ cb_state' = "queued"
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, rx_running, rx_terminating,
                   rx_pause_pending, rx_err, ier_rx_enabled, hw_ier_rx_enabled,
                   work_state, worker_retries, shutting_down, flushes,
                   delivered, completed_lost, dw_divisor_aborted>>

\* DMA controller encounters a bus/transfer error and publishes DMA_ERROR
DmaErrorIrq ==
    /\ AllowDmaError
    /\ hw_state = "active"
    /\ cookie_status = "IN_PROGRESS"
    /\ hw_state' = "idle"
    /\ cookie_status' = "ERROR"
    /\ cb_state' = "queued"
    /\ UNCHANGED <<hw_bytes, peer_done, rx_running, rx_terminating,
                   rx_pause_pending, rx_err, ier_rx_enabled, hw_ier_rx_enabled,
                   work_state, worker_retries, shutting_down, flushes,
                   delivered, completed_lost, dw_divisor_aborted>>

\* Tasklet / softirq detaches callback pointer before acquiring port->lock
DetachCallback ==
    /\ cb_state = "queued"
    /\ cb_state' = "detached"
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, rx_running,
                   rx_terminating, rx_pause_pending, rx_err, ier_rx_enabled,
                   hw_ier_rx_enabled, work_state, worker_retries, shutting_down,
                   flushes, delivered, completed_lost, dw_divisor_aborted>>

EnterCallback ==
    /\ cb_state = "detached"
    /\ cb_state' = "entered"
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, rx_running,
                   rx_terminating, rx_pause_pending, rx_err, ier_rx_enabled,
                   hw_ier_rx_enabled, work_state, worker_retries, shutting_down,
                   flushes, delivered, completed_lost, dw_divisor_aborted>>

\* 8250_dma.c:156: dma_rx_complete() under port->lock
InvokeCallback ==
    /\ cb_state = "entered"
    /\ cb_state' = "none"
    /\ IF shutting_down \/ rx_terminating \/ rx_pause_pending \/ ~rx_running THEN
           UNCHANGED <<rx_running, rx_terminating, rx_err, hw_ier_rx_enabled,
                       work_state, delivered>>
       ELSE IF cookie_status = "ERROR" THEN
           \* 8250_dma.c:169-173: status == DMA_ERROR -> serial8250_rx_dma_recover(p)
           \* + schedule_work(&dma->rx_flush_work)
           /\ rx_err' = TRUE
           /\ rx_terminating' = TRUE
           /\ hw_ier_rx_enabled' = ComputeHwIer(ier_rx_enabled, rx_pause_pending, TRUE, TRUE)
           /\ work_state' = IF work_state = "idle" THEN "queued" ELSE work_state
           /\ UNCHANGED <<rx_running, delivered>>
       ELSE IF cookie_status = "COMPLETE" THEN
           /\ rx_running' = FALSE
           /\ delivered' = delivered + ReportedCount
           /\ UNCHANGED <<rx_terminating, rx_err, hw_ier_rx_enabled, work_state>>
       ELSE
           UNCHANGED <<rx_running, rx_terminating, rx_err, hw_ier_rx_enabled,
                       work_state, delivered>>
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status,
                   rx_pause_pending, ier_rx_enabled, worker_retries,
                   shutting_down, flushes, completed_lost, dw_divisor_aborted>>

\* Asynchronous hardware stop completes after dmaengine_terminate_async()
FinishAsyncHardwareStop ==
    /\ hw_state = "stopping"
    /\ hw_state' = "idle"
    /\ UNCHANGED <<hw_bytes, peer_done, cookie_status, cb_state, rx_running,
                   rx_terminating, rx_pause_pending, rx_err, ier_rx_enabled,
                   hw_ier_rx_enabled, work_state, worker_retries, shutting_down,
                   flushes, delivered, completed_lost, dw_divisor_aborted>>

-----------------------------------------------------------------------------
(* 8250_dma.c:115: serial8250_rx_dma_try_flush() transition helper *)

\* Models one execution of serial8250_rx_dma_try_flush(p) under port->lock:
\*   pause_fails: whether dmaengine_pause(dma->rxchan) returns non-zero
\*   term_ok:     whether dmaengine_terminate_async(dma->rxchan) returns 0
TryFlushStep(pause_fails, term_ok) ==
    IF cookie_status = "ERROR" THEN
        \* 8250_dma.c:126-129: status == DMA_ERROR -> goto recover
        /\ rx_err' = TRUE
        /\ rx_terminating' = TRUE
        /\ hw_ier_rx_enabled' = ComputeHwIer(ier_rx_enabled, rx_pause_pending, TRUE, TRUE)
        /\ UNCHANGED <<hw_state, cb_state, rx_running, rx_pause_pending, delivered>>
    ELSE IF pause_fails /\ cookie_status # "COMPLETE" THEN
        \* 8250_dma.c:130-139: ret && status != DMA_COMPLETE
        /\ rx_pause_pending' = TRUE
        /\ hw_ier_rx_enabled' = ComputeHwIer(ier_rx_enabled, TRUE, rx_err, rx_terminating)
        /\ UNCHANGED <<hw_state, cb_state, rx_running, rx_terminating, rx_err, delivered>>
    ELSE
        \* Pause succeeded OR status == DMA_COMPLETE:
        \* 8250_dma.c:141-149: serial8250_rx_dma_copy() + dmaengine_terminate_async()
        /\ delivered' = delivered + ReportedCount
        /\ rx_terminating' = TRUE
        /\ IF term_ok THEN
               /\ rx_running' = FALSE
               /\ hw_state' = IF hw_state \in {"active", "paused"}
                              THEN IF AsyncHardwareStop THEN "stopping" ELSE "idle"
                              ELSE "idle"
               /\ cb_state' = IF cb_state = "queued" THEN "none" ELSE cb_state
               /\ UNCHANGED <<rx_pause_pending, rx_err, hw_ier_rx_enabled>>
           ELSE
               \* dmaengine_terminate_async() failed -> goto recover
               /\ rx_err' = TRUE
               /\ hw_ier_rx_enabled' = ComputeHwIer(ier_rx_enabled, rx_pause_pending, TRUE, TRUE)
               /\ UNCHANGED <<hw_state, cb_state, rx_running, rx_pause_pending>>

-----------------------------------------------------------------------------
(* UART ISR & DW8250 Termios Callers of serial8250_rx_dma_flush() *)

\* 8250_port.c:1819-1820, 1875 / 8250_dma.c:371: UART RX timeout / RLSI interrupt calls
\* serial8250_rx_dma_flush(up) when bytes have arrived (either peer stopped
\* after partial burst, hardware completed, or DMA error occurred).
UartRxTimeoutFlush(term_ok) ==
    /\ ~shutting_down
    /\ hw_ier_rx_enabled
    /\ flushes < MaxFlushes
    /\ rx_running
    /\ ~rx_terminating
    /\ ~rx_pause_pending
    /\ (peer_done \/ hw_state = "completed" \/ cookie_status = "ERROR")
    /\ (term_ok \/ AllowTerminateFailure)
    /\ LET pause_fails ==
           (hw_state = "completed" /\ PauseFailsWhenHwCompleted)
           \/ (hw_state = "active" /\ PauseFailsWhenHwActive)
       IN
       /\ flushes' = flushes + 1
       /\ TryFlushStep(pause_fails, term_ok)
       /\ work_state' = IF work_state = "idle" THEN "queued" ELSE work_state
       /\ UNCHANGED <<hw_bytes, peer_done, cookie_status, ier_rx_enabled,
                      worker_retries, shutting_down, completed_lost,
                      dw_divisor_aborted>>

\* 8250_dw.c:202: dw8250_set_divisor() -> dw8250_idle_enter() -> serial8250_rx_dma_flush()
\* If rx_pause_pending or rx_terminating is active (with rx_running == TRUE),
\* serial8250_rx_dma_flush() returns -EAGAIN / -EIO and dw8250_set_divisor() aborts!
Dw8250SetDivisorDuringPausePending ==
    /\ AllowDwSetDivisor
    /\ ~shutting_down
    /\ ~dw_divisor_aborted
    /\ rx_running
    /\ (rx_pause_pending \/ rx_terminating)
    /\ dw_divisor_aborted' = TRUE
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, cb_state,
                   rx_running, rx_terminating, rx_pause_pending, rx_err,
                   ier_rx_enabled, hw_ier_rx_enabled, work_state,
                   worker_retries, shutting_down, flushes, delivered,
                   completed_lost>>

-----------------------------------------------------------------------------
(* 8250_dma.c:185: serial8250_rx_dma_flush_work() *)

WorkerStart ==
    /\ work_state = "queued"
    /\ work_state' = "loop"
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, cb_state,
                   rx_running, rx_terminating, rx_pause_pending, rx_err,
                   ier_rx_enabled, hw_ier_rx_enabled, worker_retries,
                   shutting_down, flushes, delivered, completed_lost,
                   dw_divisor_aborted>>

\* 8250_dma.c:195-204: one locked iteration of the for (;;) loop in
\* serial8250_rx_dma_flush_work().
WorkerLoopIteration(pause_retry_succeeds, term_ok) ==
    /\ work_state = "loop"
    /\ (term_ok \/ AllowTerminateFailure)
    /\ (pause_retry_succeeds => PauseSucceedsOnRetry)
    /\ (~PauseSucceedsOnRetry => ~pause_retry_succeeds)
    /\ IF shutting_down THEN
           /\ work_state' = "idle"
           /\ UNCHANGED <<hw_state, cb_state, rx_running, rx_terminating,
                          rx_pause_pending, rx_err, hw_ier_rx_enabled,
                          delivered>>
       ELSE IF rx_pause_pending /\ ~rx_terminating THEN
           LET pause_fails ==
               (hw_state = "completed" /\ PauseFailsWhenHwCompleted)
               \/ (hw_state = "active" /\ PauseFailsWhenHwActive /\ ~pause_retry_succeeds)
           IN
           IF BoundPauseRetries /\ cookie_status # "ERROR" /\ pause_fails
              /\ cookie_status # "COMPLETE" /\ worker_retries >= MaxWorkerRetries - 1
           THEN
               \* Proposed fix: after bounded retries, escalate to serial8250_rx_dma_recover(p)
               \* so the worker exits the retry loop and runs dmaengine_terminate_sync().
               /\ rx_pause_pending' = TRUE
               /\ rx_err' = TRUE
               /\ rx_terminating' = TRUE
               /\ hw_ier_rx_enabled' = ComputeHwIer(ier_rx_enabled, TRUE, TRUE, TRUE)
               /\ work_state' = "recover"
               /\ UNCHANGED <<hw_state, cb_state, rx_running, delivered>>
           ELSE
               /\ TryFlushStep(pause_fails, term_ok)
               /\ work_state' =
                   IF cookie_status # "ERROR" /\ pause_fails /\ cookie_status # "COMPLETE"
                   THEN "sleeping"
                   ELSE IF cookie_status = "ERROR" \/ ~term_ok \/ rx_err
                        THEN "recover"
                        ELSE "sync"
       ELSE
           /\ work_state' = IF rx_err THEN "recover" ELSE "sync"
           /\ UNCHANGED <<hw_state, cb_state, rx_running, rx_terminating,
                          rx_pause_pending, rx_err, hw_ier_rx_enabled,
                          delivered>>
    /\ UNCHANGED <<hw_bytes, peer_done, cookie_status, ier_rx_enabled,
                   worker_retries, shutting_down, flushes, completed_lost,
                   dw_divisor_aborted>>

\* 8250_dma.c:207: usleep_range(1000, 2000) outside port->lock (IRQs enabled).
\* If hardware already completed the transfer (hw_state = "completed"), dropping
\* port->lock and sleeping 1-2 ms allows the pending DMA hardirq (DmaIrq) to
\* publish DMA_COMPLETE before usleep_range() returns.
WorkerSleepRetry ==
    /\ work_state = "sleeping"
    /\ ~(BoundPauseRetries /\ hw_state = "completed" /\ cookie_status = "IN_PROGRESS")
    /\ worker_retries' = IF worker_retries < MaxWorkerRetries
                         THEN worker_retries + 1
                         ELSE MaxWorkerRetries
    /\ work_state' = "loop"
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, cb_state,
                   rx_running, rx_terminating, rx_pause_pending, rx_err,
                   ier_rx_enabled, hw_ier_rx_enabled, shutting_down, flushes,
                   delivered, completed_lost, dw_divisor_aborted>>

\* 8250_dma.c:210-216: if (recover) dmaengine_terminate_sync(dma->rxchan)
WorkerRecoverSync(term_ok) ==
    /\ work_state = "recover"
    /\ (term_ok \/ AllowTerminateFailure)
    /\ IF term_ok THEN
           /\ (~DrainCallbacksOnSync \/ ProviderDrained \/ hw_state \in {"active", "paused", "completed", "stopping"})
           /\ hw_state' = "idle"
           /\ cb_state' = "none"
           /\ completed_lost' = (completed_lost \/ (hw_bytes = RxSize /\ delivered = 0))
           /\ work_state' = "post_sync"
       ELSE
           \* 8250_dma.c:215: return early, retaining ownership and keeping RX masked
           /\ work_state' = "idle"
           /\ UNCHANGED <<hw_state, cb_state, completed_lost>>
    /\ UNCHANGED <<hw_bytes, peer_done, cookie_status, rx_running,
                   rx_terminating, rx_pause_pending, rx_err, ier_rx_enabled,
                   hw_ier_rx_enabled, worker_retries, shutting_down, flushes,
                   delivered, dw_divisor_aborted>>

\* 8250_dma.c:218: else dmaengine_synchronize(dma->rxchan)
WorkerSynchronize ==
    /\ work_state = "sync"
    /\ (~DrainCallbacksOnSync \/ ProviderDrained)
    /\ work_state' = "post_sync"
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, cb_state,
                   rx_running, rx_terminating, rx_pause_pending, rx_err,
                   ier_rx_enabled, hw_ier_rx_enabled, worker_retries,
                   shutting_down, flushes, delivered, completed_lost,
                   dw_divisor_aborted>>

\* 8250_dma.c:221-225: final scoped_guard(uart_port_lock_irqsave, &p->port).
\* Models the state immediately after clearing rx_pause_pending, rx_terminating,
\* and rx_running (8250_dma.c:223-225), right before serial8250_rx_dma(p)
\* re-arms dma->rx_buf (or serial8250_rx_dma_Fallback_to_pio(p) re-enables RX IER).
\* Checking NoPrematureBufferReuse in this terminal state proves that dma->rx_buf
\* is never reused while the previous DMA transfer is still active, paused, or stopping.
WorkerFinish ==
    /\ work_state = "post_sync"
    /\ work_state' = "idle"
    /\ rx_pause_pending' = FALSE
    /\ rx_terminating' = FALSE
    /\ rx_running' = FALSE
    /\ hw_ier_rx_enabled' =
        IF shutting_down THEN FALSE
        ELSE IF rx_err \/ rx_pause_pending
             THEN ComputeHwIer(ier_rx_enabled, FALSE, rx_err, FALSE)
             ELSE hw_ier_rx_enabled
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, cb_state,
                   rx_err, ier_rx_enabled, worker_retries, shutting_down,
                   flushes, delivered, completed_lost, dw_divisor_aborted>>

-----------------------------------------------------------------------------
(* Port Shutdown (8250_port.c: serial8250_do_shutdown -> serial8250_release_dma) *)

ShutdownPort ==
    /\ AllowClose
    /\ ~shutting_down
    /\ shutting_down' = TRUE
    /\ ier_rx_enabled' = FALSE
    /\ hw_ier_rx_enabled' = FALSE
    /\ UNCHANGED <<hw_state, hw_bytes, peer_done, cookie_status, cb_state,
                   rx_running, rx_terminating, rx_pause_pending, rx_err,
                   work_state, worker_retries, flushes, delivered,
                   completed_lost, dw_divisor_aborted>>

-----------------------------------------------------------------------------
(* Next-State Relation & Fairness *)

ProviderStep ==
    \/ DmaIrq
    \/ DmaErrorIrq
    \/ DetachCallback
    \/ EnterCallback
    \/ InvokeCallback
    \/ FinishAsyncHardwareStop

WorkerStep ==
    \/ WorkerStart
    \/ (\E p_ok, t_ok \in BOOLEAN : WorkerLoopIteration(p_ok, t_ok))
    \/ WorkerSleepRetry
    \/ (\E t_ok \in BOOLEAN : WorkerRecoverSync(t_ok))
    \/ WorkerSynchronize
    \/ WorkerFinish

Next ==
    \/ ReceiveByte
    \/ PeerStopAfterPartialBurst
    \/ ProviderStep
    \/ (\E t_ok \in BOOLEAN : UartRxTimeoutFlush(t_ok))
    \/ Dw8250SetDivisorDuringPausePending
    \/ WorkerStep
    \/ ShutdownPort

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(ProviderStep)
    /\ WF_vars(WorkerStep)

-----------------------------------------------------------------------------
(* Safety & Liveness Invariants *)

TypeOK ==
    /\ hw_state \in {"idle", "active", "paused", "completed", "stopping"}
    /\ hw_bytes \in 0..RxSize
    /\ peer_done \in BOOLEAN
    /\ cookie_status \in {"NONE", "IN_PROGRESS", "COMPLETE", "ERROR"}
    /\ cb_state \in {"none", "queued", "detached", "entered"}
    /\ rx_running \in BOOLEAN
    /\ rx_terminating \in BOOLEAN
    /\ rx_pause_pending \in BOOLEAN
    /\ rx_err \in BOOLEAN
    /\ ier_rx_enabled \in BOOLEAN
    /\ hw_ier_rx_enabled \in BOOLEAN
    /\ work_state \in {"idle", "queued", "loop", "sleeping", "sync", "recover", "post_sync"}
    /\ worker_retries \in 0..MaxWorkerRetries
    /\ shutting_down \in BOOLEAN
    /\ flushes \in 0..MaxFlushes
    /\ delivered \in 0..(2 * RxSize)
    /\ completed_lost \in BOOLEAN
    /\ dw_divisor_aborted \in BOOLEAN

\* Never deliver more bytes than the hardware actually received
NoDuplicateDelivery ==
    delivered <= hw_bytes

\* Never discard a completed 4 KB DMA buffer when pause fails before DMA IRQ
NoCompletedRxDataLost ==
    ~completed_lost

\* Never release buffer ownership (~rx_running /\ ~rx_terminating) while DMA
\* hardware is still active/stopping
NoPrematureBufferReuse ==
    (~rx_running /\ ~rx_terminating) =>
        hw_state \notin {"active", "paused", "stopping"}

\* Invariant checking that serial8250_rx_dma_flush_work() does not get stuck
\* retrying pause forever when a partial RX transfer cannot be paused
WorkerBoundedRetries ==
    worker_retries < MaxWorkerRetries

\* Invariant checking that dw8250_set_divisor() is not silently aborted
NoAbortedDivisorProgramming ==
    ~dw_divisor_aborted

\* Temporal liveness: any queued flush work must eventually finish (return to idle)
FlushWorkProgress ==
    (work_state # "idle") ~> (work_state = "idle")

=============================================================================
