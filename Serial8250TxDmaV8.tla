----------------------- MODULE Serial8250TxDmaV8 -----------------------
EXTENDS Integers, FiniteSets, TLC

(***************************************************************************)
(* Formal TLA+ Model of Linux 8250 UART TX DMA Cancellation, Serial Core   *)
(* Write Wakeup Serialization, and Shutdown Termination Retry in           *)
(* [PATCH v8 0/6]:                                                         *)
(*   - Patch 3/6 (dc41a4f7ebbd): serial_core.c: uart_flush_buffer(),       *)
(*     uart_write_wakeup(), uart_xmit_block(), uart_xmit_unblock(),        *)
(*     and interaction with tty_wait_until_sent() (tty->write_wait)        *)
(*   - Patch 4/6 (5eb9d13feb8c): 8250_dma.c / 8250_omap.c:                 *)
(*     serial8250_flush_tx_buffer(), serial8250_tx_dma_flush_work(),       *)
(*     __dma_tx_complete() with restored `if (!dma->tx_running) return;`   *)
(*   - Patch 6/6 (118587b34be5): 8250_dma.c:                               *)
(*     serial8250_terminate_dma() unbounded while (rx_ret || tx_ret)       *)
(*     { msleep(100); ... } loop in serial8250_release_dma()               *)
(***************************************************************************)

CONSTANTS
    Capacity,                       \* xmit_fifo capacity (e.g., 2 bytes)
    MaxTransfers,                   \* Maximum DMA descriptors (e.g., 3)
    MaxWrites,                      \* Maximum uart_write() calls
    MaxFlushes,                     \* Maximum uart_flush_buffer() calls
    MaxTerminateRetries,            \* Bound for detecting infinite terminate_dma loops
    DrainCallbacksOnSync,           \* TRUE if .device_synchronize drains callbacks
    AsyncHardwareStop,              \* TRUE if terminate_async stops HW asynchronously
    CheckTxRunning,                 \* TRUE in v8 (`if (!dma->tx_running) return;`)
    CheckTxCookieStatus,            \* TRUE if callback checks dma->tx_cookie status
    FlushWakesWriteWaitDirectly,    \* FALSE in v8 Patch 3/6 (uses uart_write_wakeup)
    Patch6RetryOnTerminateFailure,  \* TRUE in v8 Patch 6/6 (loops on terminate_sync err)
    QuarantineOnTerminateFailure,   \* FALSE in v8; TRUE in proposed fix (bounded retry + quarantine)
    AllowClose,                     \* TRUE if uart_shutdown() is modeled
    AllowTerminateFailure           \* TRUE if terminate_async / terminate_sync can fail

VARIABLES
    input,                      \* kfifo in-offset (bytes written to xmit_fifo)
    output,                     \* kfifo out-offset (bytes consumed from xmit_fifo)
    writes,                     \* count of uart_write() calls
    flushes,                    \* count of uart_flush_buffer() calls
    mem,                        \* [Cells -> 1..MaxWrites]: contents of xmit_fifo
    next_id,                    \* next descriptor ID (1..MaxTransfers+1)
    current_id,                 \* active descriptor ID (0..MaxTransfers)
    tx_size,                    \* dma->tx_size
    tx_running,                 \* dma->tx_running (BOOLEAN)
    tx_terminating,             \* dma->tx_terminating (BOOLEAN)
    tx_flushed,                 \* dma->tx_flushed (BOOLEAN)
    xmit_ready,                 \* state->xmit_ready (BOOLEAN)
    xmit_blocked,               \* state->xmit_blocked (BOOLEAN)
    xmit_wakeup_pending,        \* state->xmit_wakeup_pending (BOOLEAN)
    wait_until_sent_sleeping,   \* TRUE if a thread is sleeping on tty->write_wait
                                \* in tty_wait_until_sent() waiting for input == output
    work_state,                 \* "idle", "pending", "sync", "ready"
    close_state,                \* "open", "cancel", "terminate", "sync", "free", "closed"
    terminate_retries,          \* retry count in serial8250_terminate_dma()
    freed,                      \* TRUE after dma_unmap / kfree in serial8250_release_dma
    desc                        \* [Ids -> descriptor state]

vars == <<input, output, writes, flushes, mem, next_id, current_id, tx_size,
          tx_running, tx_terminating, tx_flushed, xmit_ready, xmit_blocked,
          xmit_wakeup_pending, wait_until_sent_sleeping, work_state,
          close_state, terminate_retries, freed, desc>>

Ids == 1..MaxTransfers
Cells == 0..(Capacity - 1)
LiveCallbacks == {"detached", "entered", "executed"}
Span(lo, len) == {(lo + n) % Capacity : n \in 0..(len - 1)}

EmptyDesc ==
    [hw     |-> "unused",
     cookie |-> FALSE,
     cb     |-> "none",
     lo     |-> 0,
     len    |-> 0,
     image  |-> [a \in Cells |-> 0]]

-----------------------------------------------------------------------------
(* Initial State *)

Init ==
    /\ input = Capacity
    /\ output = 0
    /\ writes = 1
    /\ flushes = 0
    /\ mem = [a \in Cells |-> 1]
    /\ next_id = 1
    /\ current_id = 0
    /\ tx_size = 0
    /\ tx_running = FALSE
    /\ tx_terminating = FALSE
    /\ tx_flushed = FALSE
    /\ xmit_ready = TRUE
    /\ xmit_blocked = FALSE
    /\ xmit_wakeup_pending = FALSE
    /\ wait_until_sent_sleeping = FALSE
    /\ work_state = "idle"
    /\ close_state = "open"
    /\ terminate_retries = 0
    /\ freed = FALSE
    /\ desc = [i \in Ids |-> EmptyDesc]

-----------------------------------------------------------------------------
(* Helpers corresponding to serial_core.c and 8250_dma.c *)

\* serial_core.c:103: uart_xmit_writable(state)
UartXmitWritable(ready, blocked) ==
    ready /\ ~blocked

\* serial_core.c:119: uart_write_wakeup(port)
\* If uart_xmit_writable(state) is true, calls tty_port_tty_wakeup(&state->port),
\* which wakes tty->write_wait (waking tty_wait_until_sent() if input == output).
\* If !uart_xmit_writable(state), sets state->xmit_wakeup_pending = true and
\* suppresses tty_port_tty_wakeup(&state->port)!
ApplyUartWriteWakeup(ready, blocked, cur_pending, cur_sleeping, cur_in, cur_out) ==
    IF UartXmitWritable(ready, blocked) THEN
        [pending  |-> FALSE,
         sleeping |-> IF cur_in = cur_out THEN FALSE ELSE cur_sleeping]
    ELSE
        [pending  |-> TRUE,
         sleeping |-> cur_sleeping]

\* Provider quiescence check for dmaengine_synchronize()
ProviderDrained(d) ==
    /\ \A i \in Ids : d[i].hw \notin {"active", "stopping"}
    /\ \A i \in Ids : d[i].cb \notin LiveCallbacks \cup {"queued"}

\* dmaengine_terminate_async() / dmaengine_terminate_sync() effect on descriptors
TerminateDescriptors(d, sync_stop) ==
    [i \in Ids |->
        [d[i] EXCEPT
            !.hw = CASE @ = "active" ->
                        IF AsyncHardwareStop /\ ~sync_stop THEN "stopping" ELSE "stopped"
                     [] @ = "done" -> "stopped"
                     [] @ = "stopping" ->
                        IF sync_stop THEN "stopped" ELSE "stopping"
                     [] OTHER -> @,
            !.cb = IF @ = "queued" THEN "returned" ELSE @]]

\* Whether a new TX DMA transfer can start under port->lock
CanStartTx(c_state, term, blocked, running, in_pos, out_pos, nxt) ==
    /\ c_state = "open"
    /\ ~term
    /\ ~blocked
    /\ ~running
    /\ in_pos > out_pos
    /\ nxt <= MaxTransfers

-----------------------------------------------------------------------------
(* Actions *)

\* Start initial or next TX DMA transfer (serial8250_tx_dma)
StartTx ==
    /\ CanStartTx(close_state, tx_terminating, xmit_blocked, tx_running,
                  input, output, next_id)
    /\ tx_running' = TRUE
    /\ tx_flushed' = FALSE
    /\ tx_size' = input - output
    /\ current_id' = next_id
    /\ next_id' = next_id + 1
    /\ desc' = [desc EXCEPT ![next_id] =
                    [hw     |-> "active",
                     cookie |-> FALSE,
                     cb     |-> "none",
                     lo     |-> output,
                     len    |-> input - output,
                     image  |-> mem]]
    /\ UNCHANGED <<input, output, writes, flushes, mem, tx_terminating,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, close_state,
                   terminate_retries, freed>>

\* A caller (e.g., set_termios with TERMIOS_WAIT or tcdrain) invokes
\* tty_wait_until_sent() (drivers/tty/tty_ioctl.c:179) while xmit_fifo is
\* non-empty (input > output), sleeping on tty->write_wait waiting for
\* !tty_chars_in_buffer(tty) (uart_chars_in_buffer() == 0).
EnterWaitUntilSent ==
    /\ close_state = "open"
    /\ ~wait_until_sent_sleeping
    /\ input > output
    /\ wait_until_sent_sleeping' = TRUE
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   work_state, close_state, terminate_retries, freed, desc>>

\* User/tty writes n bytes into xmit_fifo (serial_core.c:707 checks
\* uart_xmit_writable(state)) and kicks TX if idle
Write(n) ==
    /\ close_state = "open"
    /\ UartXmitWritable(xmit_ready, xmit_blocked)
    /\ ~freed
    /\ writes < MaxWrites
    /\ n \in 1..(Capacity - (input - output))
    /\ LET new_in == input + n
           new_writes == writes + 1
           new_mem == [a \in Cells |->
                        IF a \in Span(input, n) THEN new_writes ELSE mem[a]]
       IN
       /\ input' = new_in
       /\ writes' = new_writes
       /\ mem' = new_mem
       /\ IF CanStartTx(close_state, tx_terminating, xmit_blocked, tx_running,
                        new_in, output, next_id)
          THEN /\ tx_running' = TRUE
               /\ tx_flushed' = FALSE
               /\ tx_size' = new_in - output
               /\ current_id' = next_id
               /\ next_id' = next_id + 1
               /\ desc' = [desc EXCEPT ![next_id] =
                            [hw     |-> "active",
                             cookie |-> FALSE,
                             cb     |-> "none",
                             lo     |-> output,
                             len    |-> new_in - output,
                             image  |-> new_mem]]
          ELSE UNCHANGED <<tx_running, tx_flushed, tx_size, current_id, next_id, desc>>
    /\ UNCHANGED <<output, flushes, tx_terminating, xmit_ready, xmit_blocked,
                   xmit_wakeup_pending, wait_until_sent_sleeping, work_state,
                   close_state, terminate_retries, freed>>

-----------------------------------------------------------------------------
(* DMA Provider Actions *)

HardwareDone(i) ==
    /\ desc[i].hw = "active"
    /\ \A j \in 1..(i - 1) : desc[j].hw \notin {"active", "stopping"}
    /\ desc' = [desc EXCEPT ![i].hw = "done"]
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, close_state,
                   terminate_retries, freed>>

DmaIrq(i) ==
    /\ desc[i].hw = "done"
    /\ ~desc[i].cookie
    /\ desc' = [desc EXCEPT ![i].cookie = TRUE, ![i].cb = "queued"]
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, close_state,
                   terminate_retries, freed>>

Capture(i) ==
    /\ desc[i].cb = "queued"
    /\ desc' = [desc EXCEPT ![i].cb = "detached"]
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, close_state,
                   terminate_retries, freed>>

Enter(i) ==
    /\ desc[i].cb = "detached"
    /\ desc' = [desc EXCEPT ![i].cb = "entered"]
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, close_state,
                   terminate_retries, freed>>

\* 8250_dma.c:15: serial8250_tx_dma_complete(p) helper
CompleteTx(d_after_cb) ==
    LET new_out == IF tx_flushed THEN output ELSE output + tx_size
        new_blocked == IF tx_flushed THEN FALSE ELSE xmit_blocked
        wakeup_res == ApplyUartWriteWakeup(xmit_ready, new_blocked,
                                           xmit_wakeup_pending,
                                           wait_until_sent_sleeping,
                                           input, new_out)
    IN
    /\ output' = new_out
    /\ xmit_blocked' = new_blocked
    /\ xmit_wakeup_pending' = wakeup_res.pending
    /\ wait_until_sent_sleeping' = wakeup_res.sleeping
    /\ IF CanStartTx(close_state, tx_terminating, new_blocked, FALSE,
                     input, new_out, next_id)
       THEN /\ tx_running' = TRUE
            /\ tx_flushed' = FALSE
            /\ tx_size' = input - new_out
            /\ current_id' = next_id
            /\ next_id' = next_id + 1
            /\ desc' = [d_after_cb EXCEPT ![next_id] =
                        [hw     |-> "active",
                         cookie |-> FALSE,
                         cb     |-> "none",
                         lo     |-> new_out,
                         len    |-> input - new_out,
                         image  |-> mem]]
       ELSE /\ tx_running' = FALSE
            /\ desc' = d_after_cb
            /\ UNCHANGED <<tx_flushed, tx_size, current_id, next_id>>

\* 8250_dma.c:41: __dma_tx_complete(void *param)
Invoke(i) ==
    /\ desc[i].cb = "entered"
    /\ ~freed
    /\ LET d1 == [desc EXCEPT ![i].cb = "executed"]
           ignored ==
               \/ close_state # "open"
               \/ tx_terminating
               \/ (CheckTxRunning /\ ~tx_running)
               \/ (CheckTxCookieStatus /\ current_id \in Ids /\ ~desc[current_id].cookie)
       IN
       IF ignored THEN
           /\ desc' = d1
           /\ UNCHANGED <<output, next_id, current_id, tx_size, tx_running,
                          tx_flushed, xmit_blocked, xmit_wakeup_pending,
                          wait_until_sent_sleeping>>
       ELSE
           CompleteTx(d1)
    /\ UNCHANGED <<input, writes, flushes, mem, tx_terminating, xmit_ready,
                   work_state, close_state, terminate_retries, freed>>

Return(i) ==
    /\ desc[i].cb = "executed"
    /\ desc' = [desc EXCEPT ![i].cb = "returned"]
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, close_state,
                   terminate_retries, freed>>

StopHardware(i) ==
    /\ desc[i].hw = "stopping"
    /\ desc' = [desc EXCEPT ![i].hw = "stopped"]
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, close_state,
                   terminate_retries, freed>>

-----------------------------------------------------------------------------
(* Patch 3/6 & Patch 4/6: uart_flush_buffer() -> serial8250_tx_dma_flush() *)

Flush(term_ok) ==
    /\ close_state = "open"
    /\ flushes < MaxFlushes
    /\ (term_ok \/ AllowTerminateFailure)
    /\ input' = 0
    /\ output' = 0
    /\ flushes' = flushes + 1
    /\ IF tx_running /\ ~tx_terminating THEN
           /\ tx_flushed' = TRUE
           /\ xmit_blocked' = TRUE
           /\ IF term_ok THEN
                  /\ tx_terminating' = TRUE
                  /\ work_state' = "pending"
                  /\ desc' = TerminateDescriptors(desc, FALSE)
              ELSE
                  \* 8250_dma.c:331-335: if dmaengine_terminate_async() fails,
                  \* clear tx_terminating = false and retain xmit_blocked until
                  \* normal completion callback runs.
                  UNCHANGED <<tx_terminating, work_state, desc>>
           /\ LET wakeup_res == ApplyUartWriteWakeup(xmit_ready, TRUE,
                                                     xmit_wakeup_pending,
                                                     wait_until_sent_sleeping,
                                                     0, 0)
              IN
              /\ xmit_wakeup_pending' = wakeup_res.pending
              /\ wait_until_sent_sleeping' =
                  IF FlushWakesWriteWaitDirectly THEN FALSE ELSE wakeup_res.sleeping
       ELSE
           /\ LET wakeup_res == ApplyUartWriteWakeup(xmit_ready, xmit_blocked,
                                                     xmit_wakeup_pending,
                                                     wait_until_sent_sleeping,
                                                     0, 0)
              IN
              /\ xmit_wakeup_pending' = wakeup_res.pending
              /\ wait_until_sent_sleeping' =
                  IF FlushWakesWriteWaitDirectly THEN FALSE ELSE wakeup_res.sleeping
           /\ UNCHANGED <<tx_flushed, xmit_blocked, tx_terminating, work_state, desc>>
    /\ UNCHANGED <<writes, mem, next_id, current_id, tx_size, tx_running,
                   xmit_ready, close_state, terminate_retries, freed>>

\* 8250_dma.c:53: serial8250_tx_dma_flush_work()
WorkerBegin ==
    /\ work_state = "pending"
    /\ work_state' = "sync"
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, close_state, terminate_retries,
                   freed, desc>>

WorkerSync ==
    /\ work_state = "sync"
    /\ (~DrainCallbacksOnSync \/ ProviderDrained(desc))
    /\ work_state' = "ready"
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, close_state, terminate_retries,
                   freed, desc>>

\* Note: Because Flush sets xmit_blocked = TRUE and uart_write() checks
\* uart_xmit_writable(state) (serial_core.c:707), no new bytes can be written
\* to xmit_fifo while xmit_blocked is TRUE, so input = output = 0 always holds
\* when WorkerFinish calls dma->tx_complete(p).
WorkerFinish ==
    /\ work_state = "ready"
    /\ work_state' = "idle"
    /\ tx_terminating' = FALSE
    /\ tx_size' = 0
    /\ IF close_state = "open" THEN
           LET wakeup_res == ApplyUartWriteWakeup(xmit_ready, FALSE,
                                                  xmit_wakeup_pending,
                                                  wait_until_sent_sleeping,
                                                  input, output)
           IN
           /\ xmit_blocked' = FALSE
           /\ xmit_wakeup_pending' = wakeup_res.pending
           /\ wait_until_sent_sleeping' = wakeup_res.sleeping
           /\ tx_running' = FALSE
       ELSE
           UNCHANGED <<tx_running, xmit_blocked, xmit_wakeup_pending,
                       wait_until_sent_sleeping>>
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_flushed, xmit_ready, close_state, terminate_retries,
                   freed, desc>>

-----------------------------------------------------------------------------
(* Shutdown / Release DMA (Patch 3/6 + Patch 4/6 + Patch 6/6) *)

\* serial_core.c: uart_shutdown() / uart_tty_port_shutdown() / uart_suspend_port()
\* sets state->xmit_ready = false BEFORE calling uport->ops->shutdown(uport),
\* which sets dma->shutting_down = true under port->lock.
CloseGate ==
    /\ AllowClose
    /\ close_state = "open"
    /\ close_state' = "cancel"
    /\ xmit_ready' = FALSE
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_blocked, xmit_wakeup_pending, wait_until_sent_sleeping,
                   work_state, terminate_retries, freed, desc>>

\* 8250_dma.c:541: cancel_work_sync(&dma->tx_flush_work)
CloseCancel ==
    /\ close_state = "cancel"
    /\ work_state \in {"idle", "pending"}
    /\ work_state' = "idle"
    /\ close_state' = "terminate"
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, terminate_retries, freed, desc>>

\* 8250_dma.c:508: serial8250_terminate_dma() in Patch 6/6 (118587b34be5)
\* When Patch6RetryOnTerminateFailure = TRUE and dmaengine_terminate_sync()
\* fails (ok = FALSE), it sleeps msleep(100) and stays in "terminate" forever
\* unless QuarantineOnTerminateFailure bounds the retry loop and quarantines
\* the failed channel/buffer without freeing xmit_buf.
CloseTerminate(ok) ==
    /\ close_state = "terminate"
    /\ (ok \/ AllowTerminateFailure)
    /\ IF ok THEN
           /\ desc' = TerminateDescriptors(desc, TRUE)
           /\ close_state' = "sync"
           /\ UNCHANGED <<terminate_retries, wait_until_sent_sleeping>>
       ELSE IF QuarantineOnTerminateFailure /\ terminate_retries >= MaxTerminateRetries - 1 THEN
           \* Proposed fix: after bounded retries, quarantine/leak the failed
           \* channel and buffer (freed remains FALSE, xmit_blocked remains set)
           \* and allow shutdown to complete cleanly.
           /\ close_state' = "closed"
           /\ wait_until_sent_sleeping' =
               IF FlushWakesWriteWaitDirectly /\ input = output
               THEN FALSE
               ELSE wait_until_sent_sleeping
           /\ UNCHANGED <<terminate_retries, desc>>
       ELSE IF Patch6RetryOnTerminateFailure THEN
           /\ close_state' = "terminate"
           /\ terminate_retries' =
               IF terminate_retries < MaxTerminateRetries
               THEN terminate_retries + 1
               ELSE MaxTerminateRetries
           /\ UNCHANGED <<desc, wait_until_sent_sleeping>>
       ELSE
           \* v7 behavior: ignored terminate_sync failure and proceeded to free
           /\ close_state' = "free"
           /\ UNCHANGED <<terminate_retries, desc, wait_until_sent_sleeping>>
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   work_state, freed>>

\* dmaengine_synchronize() inside dmaengine_terminate_sync()
CloseSync ==
    /\ close_state = "sync"
    /\ (~DrainCallbacksOnSync \/ ProviderDrained(desc))
    /\ close_state' = "free"
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_running, tx_terminating, tx_flushed,
                   xmit_ready, xmit_blocked, xmit_wakeup_pending,
                   wait_until_sent_sleeping, work_state, terminate_retries,
                   freed, desc>>

\* 8250_dma.c:556-565: dma_unmap_single() + Clear flags + uart_xmit_unblock(&p->port)
\* Notice that in uart_xmit_unblock(&p->port) (serial_core.c:185-192):
\*   state->xmit_blocked = false;
\*   if (state->xmit_wakeup_pending) uart_write_wakeup(port);
\* Because xmit_ready is ALREADY FALSE during shutdown/suspend,
\* uart_write_wakeup(port) sees !uart_xmit_writable(state) and returns early
\* without ever waking tty->write_wait!
CloseFree ==
    /\ close_state = "free"
    /\ close_state' = "closed"
    /\ freed' = TRUE
    /\ tx_running' = FALSE
    /\ tx_terminating' = FALSE
    /\ xmit_blocked' = FALSE
    /\ LET wakeup_res ==
           IF xmit_wakeup_pending
           THEN ApplyUartWriteWakeup(xmit_ready, FALSE, xmit_wakeup_pending,
                                     wait_until_sent_sleeping, input, output)
           ELSE [pending |-> FALSE, sleeping |-> wait_until_sent_sleeping]
       IN
       /\ xmit_wakeup_pending' = wakeup_res.pending
       /\ wait_until_sent_sleeping' =
           IF FlushWakesWriteWaitDirectly /\ input = output
           THEN FALSE
           ELSE wakeup_res.sleeping
    /\ UNCHANGED <<input, output, writes, flushes, mem, next_id, current_id,
                   tx_size, tx_flushed, xmit_ready, work_state,
                   terminate_retries, desc>>

-----------------------------------------------------------------------------
(* Next-State Relation & Fairness *)

ProviderProgress(i) ==
    \/ HardwareDone(i)
    \/ DmaIrq(i)
    \/ Capture(i)
    \/ Enter(i)
    \/ Invoke(i)
    \/ Return(i)
    \/ StopHardware(i)

WorkerProgress ==
    \/ WorkerBegin
    \/ WorkerSync
    \/ WorkerFinish

CloseProgress ==
    \/ CloseCancel
    \/ (\E ok \in BOOLEAN : CloseTerminate(ok))
    \/ CloseSync
    \/ CloseFree

Next ==
    \/ StartTx
    \/ EnterWaitUntilSent
    \/ (\E n \in 1..Capacity : Write(n))
    \/ (\E i \in Ids : ProviderProgress(i))
    \/ (\E ok \in BOOLEAN : Flush(ok))
    \/ WorkerProgress
    \/ CloseGate
    \/ CloseProgress

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ (\A i \in Ids : WF_vars(ProviderProgress(i)))
    /\ WF_vars(WorkerProgress)
    /\ WF_vars(CloseProgress)

-----------------------------------------------------------------------------
(* Safety & Liveness Properties *)

TypeOK ==
    /\ input \in Nat
    /\ output \in Nat
    /\ current_id \in 0..MaxTransfers
    /\ next_id \in 1..(MaxTransfers + 1)
    /\ mem \in [Cells -> 1..MaxWrites]
    /\ tx_running \in BOOLEAN
    /\ xmit_ready \in BOOLEAN
    /\ xmit_blocked \in BOOLEAN
    /\ xmit_wakeup_pending \in BOOLEAN
    /\ wait_until_sent_sleeping \in BOOLEAN
    /\ terminate_retries \in 0..MaxTerminateRetries

\* Active DMA hardware must never read from xmit_fifo cells that have been
\* overwritten by a subsequent uart_write()
NoBufferAliasing ==
    \A i \in Ids :
        desc[i].hw \in {"active", "stopping"} =>
            \A a \in Span(desc[i].lo, desc[i].len) :
                mem[a] = desc[i].image[a]

\* kfifo out-offset never exceeds in-offset, and occupancy <= Capacity
FifoAccounting ==
    /\ output <= input
    /\ input - output <= Capacity

\* DMA buffer and channel must not be freed while hardware or callbacks are live
NoUsersAtFree ==
    ~freed \/ ProviderDrained(desc)

\* Patch 3/6 check: once the port has completed shutdown (close_state = "closed")
\* and xmit_fifo is empty (input == output) with all flushes completed, no
\* tty_wait_until_sent() caller may be stranded asleep on tty->write_wait!
NoLostFlushWaiterWakeup ==
    (close_state = "closed" /\ input = output /\ work_state = "idle") =>
        ~wait_until_sent_sleeping

\* Patch 6/6 check: serial8250_terminate_dma() must not spin in an unbounded
\* msleep(100) retry loop when dmaengine_terminate_sync() fails
BoundedTerminateRetries ==
    terminate_retries < MaxTerminateRetries

\* Temporal liveness properties
ReservationProgress ==
    (xmit_blocked /\ close_state = "open") ~> (~xmit_blocked \/ close_state # "open")

ShutdownProgress ==
    (close_state # "open") ~> (close_state = "closed")

=============================================================================
