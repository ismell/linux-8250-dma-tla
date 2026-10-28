------------------------ MODULE Serial8250TxDmaV7 ------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* Formal TLA+ Specification of the Linux Kernel 8250 UART TX DMA Engine
\* Cancellation, Flush Serialization, and Circular Buffer Reuse State Machine
\* ============================================================================
\*
\* Target patch series (branch `review-8250-dma-cancel-v7`, HEAD a6847f4e885c):
\*   [PATCH v7 0/5] serial: 8250: serialize DMA cancellation with buffer reuse
\*   Author: James Hilliard <james.hilliard1@gmail.com>
\*
\* Specifically models the interactions across:
\*   - Patch 1/5 (2560ea67681d): drivers/tty/serial/8250/8250_omap.c
\*       omap_8250_tx_dma_complete(), omap_8250_dma_tx_complete(),
\*       omap_8250_tx_dma(), omap_8250_shutdown()
\*   - Patch 2/5 (8ced3368c19c): drivers/tty/serial/serial_core.c
\*       uart_write_wakeup() serialized under uart_port_lock()
\*   - Patch 3/5 (d49967650a4f): drivers/tty/serial/serial_core.c &
\*       include/linux/serial_core.h
\*       state->xmit_ready, state->xmit_blocked, uart_xmit_writable(),
\*       uart_xmit_enable(), uart_xmit_block(), uart_xmit_unblock(),
\*       __uart_start(), uart_write(), uart_write_room(), uart_flush_buffer(),
\*       uart_startup(), uart_shutdown(), uart_tty_port_shutdown(),
\*       uart_suspend_port(), uart_resume_port()
\*   - Patch 4/5 (a8aada87b562): drivers/tty/serial/8250/8250_dma.c,
\*       drivers/tty/serial/8250/8250.h, drivers/tty/serial/8250/8250_port.c
\*       dma->tx_terminating, dma->tx_flushed, dma->shutting_down,
\*       dma->tx_flush_work, serial8250_tx_dma_blocked(),
\*       serial8250_tx_dma(), serial8250_tx_dma_flush(),
\*       serial8250_tx_dma_flush_work(), serial8250_tx_dma_complete(),
\*       __dma_tx_complete(), serial8250_release_dma()
\*
\* Lock Granularity & Atomicity Model:
\*   - Every action representing a `port->lock` critical section
\*     (`uart_port_lock_irqsave` / `uart_port_lock_irq`) executes atomically.
\*   - Workqueue and resume steps that execute outside `port->lock`
\*     (`TxFlushWorkStartSync` calling `dmaengine_synchronize()`, and
\*      `UartResumeStep1Startup` calling `ops->startup()` before acquiring
\*      `uport->lock`) are modeled as separate atomic transitions so TLC
\*     explores all interleavings with concurrent ISRs, DMA callbacks,
\*     `uart_write()`, and `uart_flush_buffer()`.

CONSTANTS
    MAX_TRANSFERS,              \* Bound on number of TX DMA transfers submitted (e.g. 1 or 2)
    HAS_DEVICE_SYNCHRONIZE,     \* TRUE if dma_chan implements .device_synchronize;
                                \* FALSE for DMA controllers without it (e.g. sun6i-dma,
                                \* dw_dmac, pl330, mtk-uart-apdma) where dmaengine_synchronize()
                                \* is a no-op and cannot drain an in-flight completion tasklet
    CHECK_TX_STATUS_IN_CALLBACK,\* FALSE for v7 as submitted; TRUE to model the proposed fix
                                \* in __dma_tx_complete() (8250_dma.c:40-50) and
                                \* omap_8250_dma_tx_complete() (8250_omap.c:1126-1136) checking
                                \* `if (!dma->tx_running || dmaengine_tx_status(...) != DMA_COMPLETE) return;`
    ALLOW_SHUTDOWN,             \* TRUE to explore normal port shutdown and reopen paths
    ALLOW_SUSPEND_RESUME,       \* TRUE to explore uart_suspend_port() / uart_resume_port()
    ALLOW_SUSPEND_CLOSE_REOPEN  \* TRUE to explore suspend -> close-while-suspended -> reopen

VARIABLES
    \* --- serial_core / tty_port state (include/linux/serial_core.h, serial_core.c) ---
    port_initialized,       \* BOOLEAN: tty_port_initialized(&state->port) (serial_core.c:210, 297, 1791, 2475, 2582)
    port_suspended,         \* BOOLEAN: uport->suspended (serial_core.c:2472, 2536)
    resume_in_progress,     \* BOOLEAN: uart_resume_port() between ops->startup() (line 2573)
                            \*          and scoped_guard(uart_port_lock_irq, uport) (line 2578)
    xmit_buf_allocated,     \* BOOLEAN: state->port.xmit_buf != NULL (serial_core.c:285, 362)
    xmit_ready,             \* BOOLEAN: state->xmit_ready (serial_core.h:472, 491, 501)
    xmit_blocked,           \* BOOLEAN: state->xmit_blocked (serial_core.h:473, 496, 501, 506, 512)
    xmit_fifo_count,        \* 0..2: queued transfer segments in uport->state->port.xmit_fifo
    xmit_buf_epoch,         \* Nat: incremented whenever xmit_fifo is empty/reset and rewritten at offset 0

    \* --- 8250_dma / 8250_port state (drivers/tty/serial/8250/8250.h, 8250_dma.c, 8250_port.c) ---
    shutting_down,          \* BOOLEAN: dma->shutting_down (8250.h:168, 8250_port.c:2417, 2504)
    tx_running,             \* BOOLEAN: dma->tx_running (8250.h:164, 8250_dma.c:29, 217, 482)
    tx_terminating,         \* BOOLEAN: dma->tx_terminating (8250.h:165, 8250_dma.c:61, 267, 272, 483)
    tx_flushed,             \* BOOLEAN: dma->tx_flushed (8250.h:166, 8250_dma.c:26, 206, 265)
    tx_err,                 \* BOOLEAN: dma->tx_err (8250.h:167, 8250_dma.c:224, 240)
    rpm_tx_active,          \* BOOLEAN: up->rpm_tx_active (8250_port.c:1549, 1570, 2507)
    ier_thri,               \* BOOLEAN: UART_IER_THRI bit in up->ier (8250_dma.c:35, 226, 242)
    tx_flush_work_state,    \* {"Idle", "Pending", "Running_Sync"}: state of dma->tx_flush_work
                            \* (serial8250_tx_dma_flush_work in 8250_dma.c:52-69)

    \* --- DMA engine hardware / provider state ---
    next_transfer_id,       \* 1..(MAX_TRANSFERS + 1): next descriptor/cookie ID to allocate
    active_cookie_id,       \* 0..MAX_TRANSFERS: dma->tx_cookie (8250.h:158, 8250_dma.c:235)
    chan_transfers,          \* [1..MAX_TRANSFERS -> [state: {"Unused", "Active", "CompletedHw",
                            \*                               "TerminatedAsync", "Retired"},
                            \*                       buf_epoch: Nat,
                            \*                       callback_pending: BOOLEAN]]
    stale_cb_corrupted      \* BOOLEAN: latched TRUE if __dma_tx_complete / omap_8250_dma_tx_complete
                            \* executes serial8250_tx_dma_complete() when no transfer is running
                            \* (~tx_running) or when the active transfer has not completed in HW

vars == <<
    port_initialized, port_suspended, resume_in_progress,
    xmit_buf_allocated, xmit_ready, xmit_blocked, xmit_fifo_count, xmit_buf_epoch,
    shutting_down, tx_running, tx_terminating, tx_flushed, tx_err,
    rpm_tx_active, ier_thri, tx_flush_work_state,
    next_transfer_id, active_cookie_id, chan_transfers,
    stale_cb_corrupted
>>

TransferIds == 1..MAX_TRANSFERS

Init ==
    /\ port_initialized = TRUE
    /\ port_suspended = FALSE
    /\ resume_in_progress = FALSE
    /\ xmit_buf_allocated = TRUE
    /\ xmit_ready = TRUE
    /\ xmit_blocked = FALSE
    /\ xmit_fifo_count = 1
    /\ xmit_buf_epoch = 1
    /\ shutting_down = FALSE
    /\ tx_running = FALSE
    /\ tx_terminating = FALSE
    /\ tx_flushed = FALSE
    /\ tx_err = FALSE
    /\ rpm_tx_active = FALSE
    /\ ier_thri = FALSE
    /\ tx_flush_work_state = "Idle"
    /\ next_transfer_id = 1
    /\ active_cookie_id = 0
    /\ chan_transfers = [id \in TransferIds |->
        [state |-> "Unused",
         buf_epoch |-> 0,
         callback_pending |-> FALSE]]
    /\ stale_cb_corrupted = FALSE

\* Helper: uart_xmit_writable(state) in include/linux/serial_core.h:499-502
UartXmitWritable ==
    xmit_ready /\ ~xmit_blocked

\* Helper: serial8250_tx_dma_blocked(dma) in drivers/tty/serial/8250/8250.h:425-428
TxDmaBlocked ==
    \/ shutting_down
    \/ tx_terminating

\* Helper: preconditions for starting a new TX DMA transfer via
\* __uart_start() (serial_core.c:206-216) -> serial8250_start_tx() (8250_port.c:1563-1590)
\* -> serial8250_tx_dma() (8250_dma.c:195-249)
CanStartTxDma ==
    /\ port_initialized
    /\ UartXmitWritable
    /\ ~TxDmaBlocked
    /\ ~tx_running
    /\ xmit_fifo_count > 0
    /\ next_transfer_id <= MAX_TRANSFERS

\* =========================================================================
\* Actions
\* =========================================================================

\* 1. Writer queues data into xmit_fifo:
\*    uart_write() (drivers/tty/serial/serial_core.c:650-687)
\*    Under port->lock, checks `if (!uart_xmit_writable(state)) return 0;` (line 668)
\*    before copying into `state->port.xmit_fifo`. When `xmit_fifo` was empty
\*    (reset by `uart_flush_buffer` or drained), the new write starts at offset 0
\*    of `xmit_buf`, advancing `xmit_buf_epoch`.
UartWrite ==
    /\ ~port_suspended
    /\ xmit_buf_allocated
    /\ UartXmitWritable
    /\ xmit_fifo_count < 2
    /\ xmit_buf_epoch <= MAX_TRANSFERS + 1
    /\ xmit_fifo_count' = xmit_fifo_count + 1
    /\ xmit_buf_epoch' = IF xmit_fifo_count = 0 THEN xmit_buf_epoch + 1 ELSE xmit_buf_epoch
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_blocked,
                   shutting_down, tx_running, tx_terminating, tx_flushed, tx_err,
                   rpm_tx_active, ier_thri, tx_flush_work_state,
                   next_transfer_id, active_cookie_id, chan_transfers,
                   stale_cb_corrupted>>

\* 2. Start a new TX DMA transfer:
\*    __uart_start() (serial_core.c:206-216) -> serial8250_start_tx() (8250_port.c:1563-1590)
\*    -> serial8250_rpm_get_tx(up) (line 1570) -> serial8250_tx_dma(p) (8250_dma.c:195-249).
\*    Sets `dma->tx_running = 1`, `dma->tx_flushed = false`, `dma->tx_cookie = ...`,
\*    calls `dma_async_issue_pending(dma->txchan)`, and clears `UART_IER_THRI` if set.
StartTxDma ==
    /\ ~port_suspended
    /\ CanStartTxDma
    /\ LET tid == next_transfer_id IN
       /\ rpm_tx_active' = TRUE
       /\ tx_running' = TRUE
       /\ tx_flushed' = FALSE
       /\ tx_err' = FALSE
       /\ active_cookie_id' = tid
       /\ next_transfer_id' = tid + 1
       /\ chan_transfers' = [chan_transfers EXCEPT ![tid] =
            [state |-> "Active",
             buf_epoch |-> xmit_buf_epoch,
             callback_pending |-> FALSE]]
       /\ ier_thri' = FALSE
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_blocked,
                   xmit_fifo_count, xmit_buf_epoch, shutting_down, tx_terminating,
                   tx_flush_work_state, stale_cb_corrupted>>

\* 3. DMA Hardware finishes an Active TX transfer asynchronously:
\*    The DMA engine marks the cookie `DMA_COMPLETE` (`dma_cookie_complete` /
\*    `vchan_cookie_complete` in drivers/dma/virt-dma.h:137-148) and schedules
\*    the completion tasklet/callback (`__dma_tx_complete` / `omap_8250_dma_tx_complete`).
DmaHwComplete(tid) ==
    /\ tid \in TransferIds
    /\ chan_transfers[tid].state = "Active"
    /\ chan_transfers' = [chan_transfers EXCEPT
        ![tid].state = "CompletedHw",
        ![tid].callback_pending = TRUE]
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_blocked,
                   xmit_fifo_count, xmit_buf_epoch, shutting_down, tx_running,
                   tx_terminating, tx_flushed, tx_err, rpm_tx_active, ier_thri,
                   tx_flush_work_state, next_transfer_id, active_cookie_id,
                   stale_cb_corrupted>>

\* 4. Flush TX buffer:
\*    uart_flush_buffer() (serial_core.c:756-776) -> serial8250_flush_tx_buffer()
\*    (8250_port.c:1906-1913) -> serial8250_tx_dma_flush() (8250_dma.c:251-279):
\*      kfifo_reset(&port->xmit_fifo); // resets FIFO read/write indices to 0
\*      if (!dma->tx_running || serial8250_tx_dma_blocked(dma)) return;
\*      dma->tx_flushed = true;
\*      uart_xmit_block(&p->port);
\*      dma->tx_terminating = true;
\*      ret = dmaengine_terminate_async(dma->txchan);
\*      if (ret) {
\*          /* Keep the buffer owned by the transfer until its callback runs. */
\*          dma->tx_terminating = false;
\*          return;
\*      }
\*      schedule_work(&dma->tx_flush_work);
UartFlushBuffer(terminate_ok) ==
    /\ ~port_suspended
    /\ xmit_fifo_count' = 0
    /\ IF tx_running /\ ~TxDmaBlocked
       THEN /\ xmit_blocked' = TRUE
            /\ tx_flushed' = TRUE
            /\ IF terminate_ok
               THEN /\ tx_terminating' = TRUE
                    /\ tx_flush_work_state' =
                        IF tx_flush_work_state = "Idle" THEN "Pending" ELSE tx_flush_work_state
                    /\ chan_transfers' =
                        IF active_cookie_id \in TransferIds /\ chan_transfers[active_cookie_id].state = "Active"
                        THEN [chan_transfers EXCEPT ![active_cookie_id].state = "TerminatedAsync"]
                        ELSE chan_transfers
               ELSE \* dmaengine_terminate_async() failed: keep tx_running = TRUE,
                    \* tx_flushed = TRUE, xmit_blocked = TRUE, tx_terminating = FALSE,
                    \* so the buffer remains blocked until the normal completion callback runs.
                    /\ tx_terminating' = FALSE
                    /\ UNCHANGED <<tx_flush_work_state, chan_transfers>>
       ELSE /\ UNCHANGED <<xmit_blocked, tx_flushed, tx_terminating,
                           tx_flush_work_state, chan_transfers>>
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_buf_epoch,
                   shutting_down, tx_running, tx_err, rpm_tx_active, ier_thri,
                   next_transfer_id, active_cookie_id, stale_cb_corrupted>>

\* 5. serial8250_tx_dma_flush_work() step 1 (drivers/tty/serial/8250/8250_dma.c:52-59):
\*    Executes in workqueue context OUTSIDE `p->port.lock`:
\*      dmaengine_synchronize(dma->txchan);
\*    On DMA controllers with `.device_synchronize` (`HAS_DEVICE_SYNCHRONIZE = TRUE`),
\*    this waits for any in-flight transfer termination and drains any running/pending
\*    completion tasklet (`vchan_synchronize` -> `tasklet_kill(&vc->task)`).
\*    On DMA controllers without `.device_synchronize` (`HAS_DEVICE_SYNCHRONIZE = FALSE`),
\*    `dmaengine_synchronize()` is a no-op (`drivers/dma/dmaengine.h:1164-1169`),
\*    leaving an already-scheduled completion callback pending!
TxFlushWorkStartSync ==
    /\ tx_flush_work_state = "Pending"
    /\ tx_flush_work_state' = "Running_Sync"
    /\ chan_transfers' = [tid \in TransferIds |->
        LET tr == chan_transfers[tid] IN
        [tr EXCEPT
            !.state = IF HAS_DEVICE_SYNCHRONIZE /\ tr.state \in {"TerminatedAsync", "CompletedHw"}
                      THEN "Retired"
                      ELSE tr.state,
            !.callback_pending = IF HAS_DEVICE_SYNCHRONIZE
                                 THEN FALSE
                                 ELSE tr.callback_pending]]
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_blocked,
                   xmit_fifo_count, xmit_buf_epoch, shutting_down, tx_running,
                   tx_terminating, tx_flushed, tx_err, rpm_tx_active, ier_thri,
                   next_transfer_id, active_cookie_id, stale_cb_corrupted>>

\* 6. serial8250_tx_dma_flush_work() step 2 (drivers/tty/serial/8250/8250_dma.c:60-69):
\*    Acquires `scoped_guard(uart_port_lock_irqsave, &p->port)` and executes:
\*      dma->tx_terminating = false;
\*      dma->tx_size = 0;
\*      if (dma->shutting_down)
\*          return;
\*      dma->tx_complete(p); // serial8250_tx_dma_complete(p) or omap_8250_tx_dma_complete(p)
\*    Inside `serial8250_tx_dma_complete(p)` (8250_dma.c:21-38):
\*      dma->tx_running = 0;
\*      if (dma->tx_flushed)
\*          uart_xmit_unblock(&p->port);
\*      ret = serial8250_tx_dma(p);
\*      if (ret)
\*          serial8250_set_THRI(p);
\*    Note:
\*      1. Because `uart_flush_buffer()` reset `xmit_fifo` and set `xmit_blocked = true`,
\*         `uart_write()` was blocked throughout `tx_terminating`, so `xmit_fifo` is
\*         guaranteed empty (`xmit_fifo_count = 0`) when `serial8250_tx_dma_complete(p)`
\*         runs here; thus `serial8250_tx_dma(p)` returns 1 and enables `UART_IER_THRI`.
\*      2. Concurrent shutdown (`serial8250_do_shutdown` -> `disable_work_sync(&dma->tx_flush_work)`)
\*         is modeled atomically in `UartShutdownClose` / `UartSuspendPort`.
TxFlushWorkFinishLocked ==
    /\ tx_flush_work_state = "Running_Sync"
    /\ tx_flush_work_state' = "Idle"
    /\ tx_terminating' = FALSE
    /\ xmit_blocked' = IF tx_flushed THEN FALSE ELSE xmit_blocked
    /\ tx_running' = FALSE
    /\ ier_thri' = TRUE
    /\ active_cookie_id' = 0
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_fifo_count, xmit_buf_epoch,
                   shutting_down, tx_flushed, tx_err, rpm_tx_active,
                   next_transfer_id, chan_transfers, stale_cb_corrupted>>

\* 7. DMA TX Completion Callback:
\*    __dma_tx_complete() (drivers/tty/serial/8250/8250_dma.c:40-50) and
\*    omap_8250_dma_tx_complete() (drivers/tty/serial/8250/8250_omap.c:1126-1136).
\*
\*    In v7 (`CHECK_TX_STATUS_IN_CALLBACK = FALSE`), the callback only checks:
\*      scoped_guard(uart_port_lock_irqsave, &p->port) {
\*          if (serial8250_tx_dma_blocked(dma))
\*              return;
\*          serial8250_tx_dma_complete(p);
\*      }
\*    Unlike `dma_rx_complete()` (8250_dma.c:125-135), `__dma_tx_complete()` checks
\*    NEITHER `if (!dma->tx_running) return;` NOR
\*    `dmaengine_tx_status(dma->txchan, dma->tx_cookie, NULL) == DMA_COMPLETE`.
\*    When `CHECK_TX_STATUS_IN_CALLBACK = TRUE`, both guards are enforced.
DmaTxCompleteCallback(tid) ==
    /\ tid \in TransferIds
    /\ chan_transfers[tid].callback_pending
    /\ LET cookie_complete == (active_cookie_id \in TransferIds /\
                               chan_transfers[active_cookie_id].state = "CompletedHw")
           ignore == TxDmaBlocked \/
                     (CHECK_TX_STATUS_IN_CALLBACK /\ (~tx_running \/ ~cookie_complete))
           is_stale == (~tx_running \/ ~cookie_complete)
       IN
       /\ IF ignore
          THEN /\ chan_transfers' = [chan_transfers EXCEPT ![tid].callback_pending = FALSE]
               /\ UNCHANGED <<xmit_blocked, tx_running, tx_flushed, xmit_fifo_count, ier_thri,
                              active_cookie_id, next_transfer_id, stale_cb_corrupted>>
          ELSE /\ stale_cb_corrupted' = (stale_cb_corrupted \/ is_stale)
               /\ xmit_blocked' = IF tx_flushed THEN FALSE ELSE xmit_blocked
               /\ LET new_fifo == IF ~tx_flushed /\ xmit_fifo_count > 0
                                  THEN xmit_fifo_count - 1
                                  ELSE xmit_fifo_count
                      retired_transfers ==
                          IF active_cookie_id \in TransferIds /\ cookie_complete
                          THEN [chan_transfers EXCEPT
                                  ![tid].callback_pending = FALSE,
                                  ![active_cookie_id].state = "Retired"]
                          ELSE [chan_transfers EXCEPT ![tid].callback_pending = FALSE]
                  IN
                  /\ xmit_fifo_count' = new_fifo
                  /\ IF new_fifo > 0 /\ next_transfer_id <= MAX_TRANSFERS
                     THEN LET ntid == next_transfer_id IN
                          /\ tx_running' = TRUE
                          /\ tx_flushed' = FALSE
                          /\ active_cookie_id' = ntid
                          /\ next_transfer_id' = ntid + 1
                          /\ chan_transfers' = [retired_transfers EXCEPT
                               ![ntid] = [state |-> "Active",
                                          buf_epoch |-> xmit_buf_epoch,
                                          callback_pending |-> FALSE]]
                          /\ ier_thri' = FALSE
                     ELSE /\ tx_running' = FALSE
                          /\ ier_thri' = TRUE
                          /\ active_cookie_id' = 0
                          /\ chan_transfers' = retired_transfers
                          /\ UNCHANGED <<tx_flushed, next_transfer_id>>
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_buf_epoch,
                   shutting_down, tx_terminating, tx_err, rpm_tx_active,
                   tx_flush_work_state>>

\* 8. UART THRE Interrupt Stops TX When FIFO Is Empty:
\*    serial8250_handle_irq_locked() (8250_port.c:1879-1884) -> serial8250_tx_chars()
\*    (8250_port.c:1810-1838) -> __stop_tx() (8250_port.c:1540-1561):
\*    When `UART_IER_THRI` is enabled (`ier_thri = TRUE`), `!tx_running`, and
\*    `xmit_fifo` is empty, `__stop_tx(up)` clears `UART_IER_THRI` and calls
\*    `serial8250_rpm_put_tx(up)` (setting `up->rpm_tx_active = false`).
UartThreIrqStopTx ==
    /\ ~port_suspended
    /\ ier_thri
    /\ ~tx_running
    /\ ~tx_err
    /\ xmit_fifo_count = 0
    /\ ier_thri' = FALSE
    /\ rpm_tx_active' = FALSE
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_blocked,
                   xmit_fifo_count, xmit_buf_epoch, shutting_down, tx_running,
                   tx_terminating, tx_flushed, tx_err, tx_flush_work_state,
                   next_transfer_id, active_cookie_id, chan_transfers,
                   stale_cb_corrupted>>

\* 9. Normal Port Shutdown:
\*    uart_tty_port_shutdown() / uart_shutdown() (serial_core.c:327-368, 1788-1806)
\*    -> serial8250_do_shutdown() (8250_port.c:2484-2532)
\*    -> serial8250_release_dma() (8250_dma.c:470-505)
\*    -> uart_free_xmit_buf() (serial_core.c:356-365):
\*      - Under port->lock, clears `state->xmit_ready = false` and `tty_port_set_initialized(port, false)`.
\*      - `serial8250_do_shutdown()` sets `dma->shutting_down = true`, calls `serial8250_rpm_put_tx(up)`,
\*        and calls `serial8250_release_dma(up)`.
\*      - `serial8250_release_dma()` runs `disable_work_sync(&dma->tx_flush_work)`,
\*        `dmaengine_terminate_sync(dma->txchan)`, and under `port->lock` sets
\*        `dma->tx_running = 0`, `dma->tx_terminating = false`, and calls
\*        `uart_xmit_unblock(&p->port)` (`xmit_blocked = false`).
\*      - `uart_free_xmit_buf()` frees `xmit_buf` and runs `INIT_KFIFO(port->xmit_fifo)`
\*        (`xmit_fifo_count = 0`, `xmit_buf_allocated = false`).
UartShutdownClose ==
    /\ ALLOW_SHUTDOWN
    /\ port_initialized
    /\ ~port_suspended
    /\ port_initialized' = FALSE
    /\ xmit_ready' = FALSE
    /\ xmit_blocked' = FALSE
    /\ xmit_fifo_count' = 0
    /\ xmit_buf_allocated' = FALSE
    /\ shutting_down' = TRUE
    /\ rpm_tx_active' = FALSE
    /\ ier_thri' = FALSE
    /\ tx_flush_work_state' = "Idle"
    /\ tx_running' = FALSE
    /\ tx_terminating' = FALSE
    /\ active_cookie_id' = 0
    /\ chan_transfers' = [tid \in TransferIds |->
        [chan_transfers[tid] EXCEPT
            !.state = IF chan_transfers[tid].state \in {"Active", "TerminatedAsync", "CompletedHw"}
                      THEN "Retired"
                      ELSE chan_transfers[tid].state,
            !.callback_pending = FALSE]]
    /\ UNCHANGED <<port_suspended, resume_in_progress, xmit_buf_epoch,
                   tx_flushed, tx_err, next_transfer_id, stale_cb_corrupted>>

\* 10. Port Reopen:
\*     uart_startup() -> uart_port_startup() (serial_core.c:243-325)
\*     -> uart_alloc_xmit_buf() -> serial8250_do_startup() (8250_port.c:2291-2467)
\*     -> serial8250_request_dma() (8250_dma.c:364-468) -> uart_xmit_enable() (serial_core.c:302):
\*       - Allocates `xmit_buf`, initializes `xmit_fifo`.
\*       - `serial8250_request_dma()` resets `tx_terminating = false`, `tx_flushed = false`,
\*         `shutting_down = false`, `tx_err = 0`.
\*       - Under `port->lock`, sets `tty_port_set_initialized(port, true)` and calls
\*         `uart_xmit_enable(uport)` (`state->xmit_ready = true`).
UartPortStartup ==
    /\ (ALLOW_SHUTDOWN \/ ALLOW_SUSPEND_CLOSE_REOPEN)
    /\ ~port_initialized
    /\ ~port_suspended
    /\ ~resume_in_progress
    /\ port_initialized' = TRUE
    /\ xmit_buf_allocated' = TRUE
    /\ xmit_ready' = TRUE
    /\ shutting_down' = FALSE
    /\ tx_terminating' = FALSE
    /\ tx_flushed' = FALSE
    /\ tx_err' = FALSE
    /\ UNCHANGED <<port_suspended, resume_in_progress, xmit_blocked,
                   xmit_fifo_count, xmit_buf_epoch, tx_running,
                   rpm_tx_active, ier_thri, tx_flush_work_state,
                   next_transfer_id, active_cookie_id, chan_transfers,
                   stale_cb_corrupted>>

\* 11. System Suspend:
\*     uart_suspend_port() (drivers/tty/serial/serial_core.c:2466-2528):
\*       - Under `uport->lock`, sets `uport->suspended = 1`, `state->xmit_ready = false`,
\*         `tty_port_set_initialized(port, false)`.
\*       - Calls `ops->shutdown(uport)` (`serial8250_do_shutdown` -> `serial8250_release_dma`),
\*         which drains `tx_flush_work`, terminates DMA, and sets `tx_running = 0`,
\*         `tx_terminating = false`, and `uart_xmit_unblock(&p->port)` (`xmit_blocked = false`).
\*       - Note: `xmit_buf` and `xmit_fifo_count` remain allocated/preserved across suspend!
UartSuspendPort ==
    /\ (ALLOW_SUSPEND_RESUME \/ ALLOW_SUSPEND_CLOSE_REOPEN)
    /\ port_initialized
    /\ ~port_suspended
    /\ port_suspended' = TRUE
    /\ port_initialized' = FALSE
    /\ xmit_ready' = FALSE
    /\ xmit_blocked' = FALSE
    /\ shutting_down' = TRUE
    /\ rpm_tx_active' = FALSE
    /\ ier_thri' = FALSE
    /\ tx_flush_work_state' = "Idle"
    /\ tx_running' = FALSE
    /\ tx_terminating' = FALSE
    /\ active_cookie_id' = 0
    /\ chan_transfers' = [tid \in TransferIds |->
        [chan_transfers[tid] EXCEPT
            !.state = IF chan_transfers[tid].state \in {"Active", "TerminatedAsync", "CompletedHw"}
                      THEN "Retired"
                      ELSE chan_transfers[tid].state,
            !.callback_pending = FALSE]]
    /\ UNCHANGED <<resume_in_progress, xmit_buf_allocated,
                   xmit_fifo_count, xmit_buf_epoch, tx_flushed, tx_err,
                   next_transfer_id, stale_cb_corrupted>>

\* 12a. System Resume Step 1 (outside final uport->lock block):
\*      uart_resume_port() (drivers/tty/serial/serial_core.c:2530-2577):
\*      When `tty_port_suspended(port)` is true (`port_suspended /\ xmit_buf_allocated`),
\*      clears `uport->suspended = 0`, calls `ops->startup(uport)` (`serial8250_do_startup`
\*      -> `serial8250_request_dma`, clearing `shutting_down = false`, `tx_terminating = false`,
\*      `tx_flushed = false`), and calls `uart_change_line_settings()` before acquiring
\*      `uport->lock` at line 2578.
UartResumeStep1Startup ==
    /\ ALLOW_SUSPEND_RESUME
    /\ port_suspended
    /\ ~port_initialized
    /\ xmit_buf_allocated
    /\ port_suspended' = FALSE
    /\ resume_in_progress' = TRUE
    /\ shutting_down' = FALSE
    /\ tx_terminating' = FALSE
    /\ tx_flushed' = FALSE
    /\ tx_err' = FALSE
    /\ UNCHANGED <<port_initialized, xmit_buf_allocated, xmit_ready, xmit_blocked,
                   xmit_fifo_count, xmit_buf_epoch, tx_running, rpm_tx_active,
                   ier_thri, tx_flush_work_state, next_transfer_id, active_cookie_id,
                   chan_transfers, stale_cb_corrupted>>

\* 12b. System Resume Step 2 (atomic block under uport->lock):
\*      uart_resume_port() (drivers/tty/serial/serial_core.c:2578-2584):
\*        scoped_guard(uart_port_lock_irq, uport) {
\*            if (!(uport->rs485.flags & SER_RS485_ENABLED))
\*                ops->set_mctrl(uport, uport->mctrl);
\*            ops->start_tx(uport);
\*            tty_port_set_initialized(port, true);
\*            uart_xmit_enable(uport);
\*        }
\*      If `xmit_fifo_count > 0` was preserved across suspend, `ops->start_tx(uport)`
\*      immediately starts a TX DMA transfer (`rpm_tx_active = TRUE`, `tx_running = TRUE`).
UartResumeStep2EnableLocked ==
    /\ ALLOW_SUSPEND_RESUME
    /\ resume_in_progress
    /\ resume_in_progress' = FALSE
    /\ port_initialized' = TRUE
    /\ xmit_ready' = TRUE
    /\ IF ~TxDmaBlocked /\ ~tx_running /\ xmit_fifo_count > 0 /\ next_transfer_id <= MAX_TRANSFERS
       THEN LET tid == next_transfer_id IN
            /\ rpm_tx_active' = TRUE
            /\ tx_running' = TRUE
            /\ tx_flushed' = FALSE
            /\ active_cookie_id' = tid
            /\ next_transfer_id' = tid + 1
            /\ chan_transfers' = [chan_transfers EXCEPT ![tid] =
                 [state |-> "Active",
                  buf_epoch |-> xmit_buf_epoch,
                  callback_pending |-> FALSE]]
       ELSE UNCHANGED <<rpm_tx_active, tx_running, tx_flushed,
                        active_cookie_id, next_transfer_id, chan_transfers>>
    /\ UNCHANGED <<port_suspended, xmit_buf_allocated, xmit_blocked,
                   xmit_fifo_count, xmit_buf_epoch, shutting_down,
                   tx_terminating, tx_err, ier_thri,
                   tx_flush_work_state, stale_cb_corrupted>>

\* 13a. Close While Suspended:
\*      uart_tty_port_shutdown() (drivers/tty/serial/serial_core.c:1817-1847) runs while
\*      `uport->suspended == 1` (`port_suspended = TRUE`), calling `tty_port_set_suspended(port, false)`
\*      (line 1842) and `uart_free_xmit_buf(port)` (line 1844, freeing `xmit_buf` and resetting
\*      `xmit_fifo`), while `uport->suspended` remains 1 until system resume.
UartCloseWhileSuspended ==
    /\ ALLOW_SUSPEND_CLOSE_REOPEN
    /\ port_suspended
    /\ ~port_initialized
    /\ xmit_buf_allocated
    /\ xmit_buf_allocated' = FALSE
    /\ xmit_fifo_count' = 0
    /\ UNCHANGED <<port_initialized, port_suspended, resume_in_progress,
                   xmit_ready, xmit_blocked, xmit_buf_epoch,
                   shutting_down, tx_running, tx_terminating, tx_flushed, tx_err,
                   rpm_tx_active, ier_thri, tx_flush_work_state,
                   next_transfer_id, active_cookie_id, chan_transfers,
                   stale_cb_corrupted>>

\* 13b. System Resume After Close-While-Suspended:
\*      uart_resume_port() (drivers/tty/serial/serial_core.c:2530, 2561):
\*      Clears `uport->suspended = 0` (`port_suspended' = FALSE`) and sees
\*      `!tty_port_suspended(port)` (`~xmit_buf_allocated`), returning without
\*      calling `ops->startup(uport)`.
UartResumeClosedPort ==
    /\ ALLOW_SUSPEND_CLOSE_REOPEN
    /\ port_suspended
    /\ ~port_initialized
    /\ ~xmit_buf_allocated
    /\ port_suspended' = FALSE
    /\ UNCHANGED <<port_initialized, resume_in_progress,
                   xmit_buf_allocated, xmit_ready, xmit_blocked, xmit_fifo_count, xmit_buf_epoch,
                   shutting_down, tx_running, tx_terminating, tx_flushed, tx_err,
                   rpm_tx_active, ier_thri, tx_flush_work_state,
                   next_transfer_id, active_cookie_id, chan_transfers,
                   stale_cb_corrupted>>

Next ==
    \/ UartWrite
    \/ StartTxDma
    \/ \E tid \in TransferIds : DmaHwComplete(tid)
    \/ TxFlushWorkStartSync
    \/ TxFlushWorkFinishLocked
    \/ \E ok \in {TRUE, FALSE} : UartFlushBuffer(ok)
    \/ \E tid \in TransferIds : DmaTxCompleteCallback(tid)
    \/ UartThreIrqStopTx
    \/ UartShutdownClose
    \/ UartPortStartup
    \/ UartSuspendPort
    \/ UartResumeStep1Startup
    \/ UartResumeStep2EnableLocked
    \/ UartCloseWhileSuspended
    \/ UartResumeClosedPort

\* =========================================================================
\* Safety Invariants
\* =========================================================================

TypeOK ==
    /\ port_initialized \in BOOLEAN
    /\ port_suspended \in BOOLEAN
    /\ resume_in_progress \in BOOLEAN
    /\ xmit_buf_allocated \in BOOLEAN
    /\ xmit_ready \in BOOLEAN
    /\ xmit_blocked \in BOOLEAN
    /\ xmit_fifo_count \in 0..2
    /\ shutting_down \in BOOLEAN
    /\ tx_running \in BOOLEAN
    /\ tx_terminating \in BOOLEAN
    /\ tx_flushed \in BOOLEAN
    /\ tx_err \in BOOLEAN
    /\ rpm_tx_active \in BOOLEAN
    /\ ier_thri \in BOOLEAN
    /\ tx_flush_work_state \in {"Idle", "Pending", "Running_Sync"}

\* INVARIANT 1: No Buffer Aliasing / Concurrent DMA Overwrite
\*   (a) No currently Active hardware DMA transfer may read from an older `xmit_buf_epoch`
\*       after the circular buffer has been reset to offset 0 and rewritten with a newer epoch.
\*   (b) No two TX DMA transfers may be simultaneously Active on `dma->txchan`.
NoBufferAliasing ==
    /\ \A tid \in TransferIds :
        (chan_transfers[tid].state = "Active" /\ xmit_fifo_count > 0)
            => (chan_transfers[tid].buf_epoch = xmit_buf_epoch)
    /\ \A t1, t2 \in TransferIds :
        (chan_transfers[t1].state = "Active" /\ chan_transfers[t2].state = "Active")
            => (t1 = t2)

\* INVARIANT 2: No Stale Callback State Corruption
\*   `__dma_tx_complete()` / `omap_8250_dma_tx_complete()` must never execute
\*   `serial8250_tx_dma_complete()` when no transfer is running (`~tx_running`) or
\*   when the currently active transfer (`active_cookie_id`) has not completed in hardware.
NoStaleCallbackCorruption ==
    ~stale_cb_corrupted

\* INVARIANT 3: No Runtime PM TX Reference Leak Across Shutdown
\*   Once the port is shut down and `tx_flush_work` is idle, `up->rpm_tx_active` must be FALSE.
NoRpmTxLeakOnShutdown ==
    (shutting_down /\ tx_flush_work_state = "Idle") => ~rpm_tx_active

\* INVARIANT 4: No Permanently Stuck `xmit_blocked`
\*   When the port is initialized, not shutting down, not terminating TX DMA,
\*   `tx_flush_work` is Idle, and no flushed transfer is waiting for its normal callback,
\*   `state->xmit_blocked` must be FALSE.
NoDeadlockOrStuckBlocked ==
    (port_initialized /\ ~shutting_down /\ ~tx_terminating /\ tx_flush_work_state = "Idle" /\ ~tx_running)
        => ~xmit_blocked

=============================================================================
