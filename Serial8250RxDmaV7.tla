------------------------ MODULE Serial8250RxDmaV7 ------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* Formal TLA+ Specification of the Linux Kernel 8250 UART RX DMA Engine
\* Cancellation, Timeout Flush, Recovery, and Buffer Reuse State Machine
\* ============================================================================
\*
\* Target patch series (branch `review-8250-dma-cancel-v7`, HEAD a6847f4e885c):
\*   [PATCH v7 5/5] serial: 8250: retire canceled RX DMA before reusing the receive buffer
\*   Author: James Hilliard <james.hilliard1@gmail.com>
\*
\* Specifically models:
\*   - drivers/tty/serial/8250/8250_dma.c:
\*       serial8250_rx_dma_copy() (lines 89-102),
\*       serial8250_rx_dma_recover() (lines 104-112),
\*       dma_rx_complete() (lines 114-140),
\*       serial8250_rx_dma_flush_work() (lines 142-179),
\*       serial8250_rx_dma() (lines 281-309),
\*       serial8250_rx_dma_flush() (lines 311-352),
\*       serial8250_request_dma() (lines 364-468),
\*       serial8250_release_dma() (lines 470-505)
\*   - drivers/tty/serial/8250/8250_port.c:
\*       handle_rx_dma() (lines 1840-1859),
\*       serial8250_handle_irq_locked() (lines 1861-1904),
\*       serial8250_do_startup() (lines 2291-2467),
\*       serial8250_do_shutdown() (lines 2484-2532)
\*   - drivers/tty/serial/8250/8250.h:
\*       serial8250_rx_dma_running() (lines 430-433),
\*       serial8250_rx_dma_recovering() (lines 435-439),
\*       serial8250_out_IER() (lines 441-449)
\*   - DMA Engine Providers:
\*       drivers/dma/virt-dma.c, drivers/dma/virt-dma.h,
\*       drivers/dma/dw-axi-dmac/dw-axi-dmac-platform.c (lines 1068-1079, 1244-1274),
\*       drivers/dma/pl330.c, drivers/dma/dw/core.c
\*
\* Lock Granularity & Atomicity Model:
\*   - Every action under `p->port.lock` (`uart_port_lock_irqsave`) executes atomically.
\*   - In `serial8250_rx_dma_flush_work()` (8250_dma.c:142-179), the worker acquires
\*     `p->port.lock` twice with an unlocked `dmaengine_terminate_sync()` /
\*     `dmaengine_synchronize()` call in between (lines 150-162 vs lines 166-177).
\*     This is modeled as two separate actions (`RxFlushWorkStartSync` and
\*     `RxFlushWorkFinishLocked`) so TLC explores all interleavings with ISRs,
\*     DMA completions, and port shutdown.

CONSTANTS
    MAX_TRANSFERS,                    \* Bound on number of RX DMA transfers (e.g. 2)
    HAS_DEVICE_SYNCHRONIZE,           \* TRUE if dma_chan implements .device_synchronize
    ALLOW_PAUSE_FAIL_ON_COMPLETE,     \* TRUE if dmaengine_pause() returns non-zero when the transfer
                                      \* has already finished in hardware (e.g. -EAGAIN on dw-axi-dmac
                                      \* because DMAC_CHEN already self-cleared so DWAXIDMAC_IRQ_SUSPENDED
                                      \* never sets; or -EINVAL on sun6i-dma/mtk-uart-apdma)
    ALLOW_HW_DONE_COOKIE_IN_PROGRESS, \* TRUE if DMA hardware can finish transferring the RX buffer
                                      \* before the DMA IRQ/tasklet updates chan->completed_cookie
                                      \* to DMA_COMPLETE:
                                      \*   (a) On dw-axi-dmac: serial8250_handle_irq_locked() holds
                                      \*       port->lock with local IRQs disabled (uart_port_lock_irqsave);
                                      \*       if dw_axi_dma_interrupt() is routed to the same CPU, it
                                      \*       cannot run vchan_cookie_complete() while serial8250_rx_dma_flush()
                                      \*       is executing!
                                      \*   (b) On pl330 / dw_dmac / dw-edma: dma_cookie_complete() is
                                      \*       deferred to a bottom-half tasklet/workqueue.
    HANDLE_HW_DONE_PAUSE_FAIL,        \* FALSE for v7 as submitted; TRUE to model the proposed fix where
                                      \* a pause failure on a hardware-finished transfer (state.residue == 0)
                                      \* still copies the completed buffer and retires normally instead of
                                      \* jumping to `recover:` before `serial8250_rx_dma_copy()`
    ALLOW_PAUSE_FAIL_ACTIVE,          \* TRUE if dmaengine_pause() can fail while transfer is still Active
    ALLOW_TERMINATE_ASYNC_FAIL,       \* TRUE if dmaengine_terminate_async() can fail after pause + copy
    ALLOW_REOPEN_WITHOUT_DMA          \* TRUE if serial8250_request_dma() can fail (-ENODEV) on reopen

VARIABLES
    \* --- UART hardware & port state ---
    port_open,              \* BOOLEAN: port is open (between serial8250_do_startup and serial8250_do_shutdown)
    uart_fifo_has_data,     \* BOOLEAN: UART_LSR_DR set in hardware RX FIFO
    ier_rdi_shadow,         \* BOOLEAN: UART_IER_RDI bit set in software shadow `up->ier`
    hw_ier_rx_enabled,      \* BOOLEAN: UART_IER_RDI bit actually enabled in hardware `UART_IER` register

    \* --- 8250_dma RX state (drivers/tty/serial/8250/8250.h:154-171) ---
    dma_attached,           \* BOOLEAN: up->dma != NULL (8250_port.c:2419)
    shutting_down,          \* BOOLEAN: dma->shutting_down (8250.h:168)
    rx_running,             \* BOOLEAN: dma->rx_running (8250.h:169)
    rx_terminating,         \* BOOLEAN: dma->rx_terminating (8250.h:170)
    rx_err,                 \* BOOLEAN: dma->rx_err (8250.h:171)
    rx_flush_work_state,    \* {"Idle", "Pending", "Running_Sync"}: state of dma->rx_flush_work
    rx_flush_work_recover,  \* BOOLEAN: `recover = dma->rx_err` snapshot in serial8250_rx_dma_flush_work (8250_dma.c:151)

    \* --- DMA channel & transfer state ---
    next_transfer_id,       \* 1..(MAX_TRANSFERS + 1)
    active_rx_cookie,       \* 0..MAX_TRANSFERS: dma->rx_cookie (8250.h:159)
    chan_transfers,          \* [1..MAX_TRANSFERS -> [state: {"Unused", "Active", "Paused",
                            \*                               "CompletedHwCookieInProgress",
                            \*                               "CompletedHw", "TerminatedAsync", "Retired"},
                            \*                       copy_count: 0..2,
                            \*                       callback_pending: BOOLEAN]]
    completed_rx_data_lost, \* BOOLEAN: latched TRUE if a hardware-completed RX DMA buffer (up to 4 KB)
                            \*          is discarded by jumping to `recover:` before `serial8250_rx_dma_copy()`
    spurious_rx_err,        \* BOOLEAN: latched TRUE if `dma->rx_err` is permanently latched when
                            \*          neither an active-transfer pause failure nor a terminate_async
                            \*          failure occurred (i.e. on a normal hardware-completed transfer)
    unhandled_rx_irq_storm  \* BOOLEAN: latched TRUE if hardware fires an RX IRQ that is neither
                            \*          handled (FIFO drained) nor masked in hardware `UART_IER`

vars == <<
    port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
    dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
    rx_flush_work_state, rx_flush_work_recover,
    next_transfer_id, active_rx_cookie, chan_transfers,
    completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm
>>

TransferIds == 1..MAX_TRANSFERS

\* Helper: serial8250_rx_dma_recovering(up) in drivers/tty/serial/8250/8250.h:435-439
RxDmaRecovering ==
    dma_attached /\ rx_err /\ rx_terminating

\* Helper: serial8250_out_IER(up, up->ier) hardware effect in drivers/tty/serial/8250/8250.h:441-449
\* Masks UART_IER_RDI | UART_IER_RLSI when `up->dma && up->dma->shutting_down` or
\* `serial8250_rx_dma_recovering(up)`.
ComputeHwIerRx(shadow_rdi, is_shutting_down, is_recovering) ==
    IF is_shutting_down THEN FALSE
    ELSE IF is_recovering THEN FALSE
    ELSE shadow_rdi

Init ==
    /\ port_open = TRUE
    /\ uart_fifo_has_data = TRUE
    /\ ier_rdi_shadow = TRUE
    /\ hw_ier_rx_enabled = TRUE
    /\ dma_attached = TRUE
    /\ shutting_down = FALSE
    /\ rx_running = FALSE
    /\ rx_terminating = FALSE
    /\ rx_err = FALSE
    /\ rx_flush_work_state = "Idle"
    /\ rx_flush_work_recover = FALSE
    /\ next_transfer_id = 1
    /\ active_rx_cookie = 0
    /\ chan_transfers = [id \in TransferIds |->
        [state |-> "Unused",
         copy_count |-> 0,
         callback_pending |-> FALSE]]
    /\ completed_rx_data_lost = FALSE
    /\ spurious_rx_err = FALSE
    /\ unhandled_rx_irq_storm = FALSE

\* =========================================================================
\* Actions
\* =========================================================================

\* 1. Start RX DMA transfer:
\*    serial8250_rx_dma(up) (drivers/tty/serial/8250/8250_dma.c:281-309)
\*    Checks `if (dma->shutting_down) return -ESHUTDOWN;`,
\*    `if (dma->rx_err || dma->rx_running || dma->rx_terminating) return -EIO;`,
\*    prepares descriptor on `dma->rx_buf`, sets `dma->rx_running = 1`,
\*    submits `dma->rx_cookie`, and calls `dma_async_issue_pending(dma->rxchan)`.
StartRxDma ==
    /\ port_open
    /\ dma_attached
    /\ ~shutting_down
    /\ ~rx_err
    /\ ~rx_running
    /\ ~rx_terminating
    /\ next_transfer_id <= MAX_TRANSFERS
    /\ LET tid == next_transfer_id IN
       /\ rx_running' = TRUE
       /\ active_rx_cookie' = tid
       /\ next_transfer_id' = tid + 1
       /\ chan_transfers' = [chan_transfers EXCEPT ![tid] =
            [state |-> "Active",
             copy_count |-> 0,
             callback_pending |-> FALSE]]
    /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                   dma_attached, shutting_down, rx_terminating, rx_err,
                   rx_flush_work_state, rx_flush_work_recover,
                   completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>

\* 2a. DMA Hardware finishes the block transfer on the bus BEFORE the DMA IRQ handler /
\*     tasklet / workqueue calls `dma_cookie_complete()` / `vchan_cookie_complete()`:
\*       - On `dw-axi-dmac` (drivers/dma/dw-axi-dmac/dw-axi-dmac-platform.c:1068-1079, 1244-1274):
\*         when `serial8250_handle_irq_locked()` holds `port->lock` with local IRQs disabled
\*         (`uart_port_lock_irqsave`), `dw_axi_dma_interrupt()` cannot run on that CPU, so
\*         `vchan_cookie_complete()` has not updated `chan->completed_cookie` (`dma_cookie_status`
\*         still returns `DMA_IN_PROGRESS`), yet the hardware channel has already completed
\*         all blocks (`state.residue == 0`) and cleared `DMAC_CHEN`, causing `dma_chan_pause()`
\*         to time out polling `DWAXIDMAC_IRQ_SUSPENDED` and return `-EAGAIN`!
\*       - On `pl330` / `dw_dmac` / `dw-edma`: `dma_cookie_complete()` is deferred to a
\*         bottom-half tasklet or workqueue (`pl330_tasklet`, `dw_dma_tasklet`, `dw_edma_irq_work`).
DmaRxHwFinishBeforeCookieUpdate(tid) ==
    /\ ALLOW_HW_DONE_COOKIE_IN_PROGRESS
    /\ tid \in TransferIds
    /\ chan_transfers[tid].state = "Active"
    /\ chan_transfers' = [chan_transfers EXCEPT
        ![tid].state = "CompletedHwCookieInProgress"]
    /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                   dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                   rx_flush_work_state, rx_flush_work_recover,
                   next_transfer_id, active_rx_cookie,
                   completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>

\* 2b. DMA IRQ / tasklet marks cookie `DMA_COMPLETE` and schedules `dma_rx_complete` callback:
DmaRxHwComplete(tid) ==
    /\ tid \in TransferIds
    /\ chan_transfers[tid].state \in {"Active", "CompletedHwCookieInProgress"}
    /\ chan_transfers' = [chan_transfers EXCEPT
        ![tid].state = "CompletedHw",
        ![tid].callback_pending = TRUE]
    /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                   dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                   rx_flush_work_state, rx_flush_work_recover,
                   next_transfer_id, active_rx_cookie,
                   completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>

\* 3. DMA RX Completion Callback:
\*    dma_rx_complete() (drivers/tty/serial/8250/8250_dma.c:114-140):
\*      scoped_guard(uart_port_lock_irqsave, &p->port) {
\*          if (dma->shutting_down || dma->rx_terminating)
\*              return;
\*          if (dma->rx_running) {
\*              status = dmaengine_tx_status(dma->rxchan, dma->rx_cookie, &state);
\*              if (status == DMA_ERROR) {
\*                  serial8250_rx_dma_recover(p);
\*                  return;
\*              }
\*              if (status != DMA_COMPLETE)
\*                  return;
\*              serial8250_rx_dma_copy(p, &state);
\*              dma->rx_running = 0;
\*          }
\*          /* Preserve LSR read side effects when stop_rx() has disabled resubmission. */
\*          if ((serial_lsr_in(p) & UART_LSR_DR) && (p->ier & UART_IER_RDI))
\*              dma->rx_dma(p);
\*      }
\*    Note: Because `dma_rx_complete()` checks `if (dma->rx_running)` and
\*    `if (status != DMA_COMPLETE) return;` before calling `serial8250_rx_dma_copy()`,
\*    it is immune to double-copying or corrupting an active transfer even when
\*    `HAS_DEVICE_SYNCHRONIZE = FALSE`.
DmaRxCompleteCallback(tid) ==
    /\ tid \in TransferIds
    /\ chan_transfers[tid].callback_pending
    /\ LET blocked == (shutting_down \/ rx_terminating)
           cookie_complete == (active_rx_cookie \in TransferIds /\
                               chan_transfers[active_rx_cookie].state = "CompletedHw")
       IN
       IF blocked \/ (rx_running /\ ~cookie_complete)
       THEN /\ chan_transfers' = [chan_transfers EXCEPT ![tid].callback_pending = FALSE]
            /\ UNCHANGED <<rx_running, active_rx_cookie, next_transfer_id>>
       ELSE LET copied_transfers ==
                    IF rx_running /\ active_rx_cookie \in TransferIds
                    THEN [chan_transfers EXCEPT
                            ![tid].callback_pending = FALSE,
                            ![active_rx_cookie].state = "Retired",
                            ![active_rx_cookie].copy_count =
                                IF chan_transfers[active_rx_cookie].copy_count < 2
                                THEN chan_transfers[active_rx_cookie].copy_count + 1
                                ELSE 2]
                    ELSE [chan_transfers EXCEPT ![tid].callback_pending = FALSE]
            IN
            IF uart_fifo_has_data /\ ier_rdi_shadow /\ ~rx_err /\ next_transfer_id <= MAX_TRANSFERS
            THEN LET ntid == next_transfer_id IN
                 /\ rx_running' = TRUE
                 /\ active_rx_cookie' = ntid
                 /\ next_transfer_id' = ntid + 1
                 /\ chan_transfers' = [copied_transfers EXCEPT
                      ![ntid] = [state |-> "Active",
                                 copy_count |-> 0,
                                 callback_pending |-> FALSE]]
            ELSE /\ rx_running' = FALSE
                 /\ active_rx_cookie' = 0
                 /\ chan_transfers' = copied_transfers
                 /\ UNCHANGED next_transfer_id
    /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                   dma_attached, shutting_down, rx_terminating, rx_err,
                   rx_flush_work_state, rx_flush_work_recover,
                   completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>

\* 4. UART IRQ Handler:
\*    serial8250_handle_irq_locked() (8250_port.c:1861-1904)
\*    -> handle_rx_dma() (8250_port.c:1840-1859)
\*    -> serial8250_rx_dma_flush() (8250_dma.c:311-352):
\*      if (!dma || !dma->rx_running) return 0;
\*      if (dma->shutting_down) return -ESHUTDOWN;
\*      if (dma->rx_terminating) return -EIO;
\*      ret = dmaengine_pause(dma->rxchan);
\*      status = dmaengine_tx_status(dma->rxchan, dma->rx_cookie, &state);
\*      if (ret && status != DMA_COMPLETE)
\*          goto recover;
\*      if (status == DMA_ERROR) {
\*          ret = -EIO;
\*          goto recover;
\*      }
\*      serial8250_rx_dma_copy(p, &state);
\*      dma->rx_terminating = true;
\*      ret = dmaengine_terminate_async(dma->rxchan);
\*      if (ret)
\*          goto recover;
\*      dma->rx_running = 0;
\*      schedule_work(&dma->rx_flush_work);
\*      return 0;
\*    recover:
\*      serial8250_rx_dma_recover(p);
\*      return ret;
UartRxIrq(is_timeout, pause_fails_active, terminate_async_fails) ==
    /\ port_open
    /\ hw_ier_rx_enabled
    /\ uart_fifo_has_data
    /\ IF RxDmaRecovering
       THEN \* `skip_rx = true` at 8250_port.c:1872 while `hw_ier_rx_enabled` was TRUE!
            /\ unhandled_rx_irq_storm' = TRUE
            /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                           dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                           rx_flush_work_state, rx_flush_work_recover,
                           next_transfer_id, active_rx_cookie, chan_transfers,
                           completed_rx_data_lost, spurious_rx_err>>
       ELSE IF ~dma_attached
            THEN \* Pure PIO mode (`up->dma == NULL`): `serial8250_rx_chars()` drains the FIFO.
                 /\ uart_fifo_has_data' = FALSE
                 /\ UNCHANGED <<port_open, ier_rdi_shadow, hw_ier_rx_enabled,
                                dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                                rx_flush_work_state, rx_flush_work_recover,
                                next_transfer_id, active_rx_cookie, chan_transfers,
                                completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>
            ELSE \* `handle_rx_dma(up, iir)` (8250_port.c:1840-1859):
                 IF ~is_timeout
                 THEN \* Non-timeout RX IRQ (`default:` branch): if `!up->dma->rx_running`,
                      \* calls `up->dma->rx_dma(up)`.
                      IF ~rx_running /\ ~shutting_down /\ ~rx_err /\ ~rx_terminating /\ next_transfer_id <= MAX_TRANSFERS
                      THEN LET tid == next_transfer_id IN
                           /\ rx_running' = TRUE
                           /\ active_rx_cookie' = tid
                           /\ next_transfer_id' = tid + 1
                           /\ chan_transfers' = [chan_transfers EXCEPT ![tid] =
                                [state |-> "Active",
                                 copy_count |-> 0,
                                 callback_pending |-> FALSE]]
                           /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                                          dma_attached, shutting_down, rx_terminating, rx_err,
                                          rx_flush_work_state, rx_flush_work_recover,
                                          completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>
                      ELSE \* If `!rx_running` and `rx_dma(up)` returned true (-EIO), `handle_rx_dma`
                           \* returns false and `serial8250_rx_chars()` drains the FIFO via PIO.
                           /\ uart_fifo_has_data' = IF ~rx_running THEN FALSE ELSE uart_fifo_has_data
                           /\ UNCHANGED <<port_open, ier_rdi_shadow, hw_ier_rx_enabled,
                                          dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                                          rx_flush_work_state, rx_flush_work_recover,
                                          next_transfer_id, active_rx_cookie, chan_transfers,
                                          completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>
                 ELSE \* `UART_IIR_RX_TIMEOUT`: calls `serial8250_rx_dma_flush(up)`
                      IF ~rx_running
                      THEN \* `serial8250_rx_dma_flush()` returns 0 -> `handle_rx_dma()` returns false
                           \* -> `serial8250_rx_chars()` drains the FIFO via PIO.
                           /\ uart_fifo_has_data' = FALSE
                           /\ UNCHANGED <<port_open, ier_rdi_shadow, hw_ier_rx_enabled,
                                          dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                                          rx_flush_work_state, rx_flush_work_recover,
                                          next_transfer_id, active_rx_cookie, chan_transfers,
                                          completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>
                      ELSE IF shutting_down \/ rx_terminating
                           THEN \* `serial8250_rx_dma_flush()` returns -ESHUTDOWN / -EIO while `rx_running == 1`,
                                \* so `handle_rx_dma()` returns true and skips `serial8250_rx_chars()`!
                                /\ unhandled_rx_irq_storm' = TRUE
                                /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                                               dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                                               rx_flush_work_state, rx_flush_work_recover,
                                               next_transfer_id, active_rx_cookie, chan_transfers,
                                               completed_rx_data_lost, spurious_rx_err>>
                           ELSE \* `rx_running` is TRUE and `~shutting_down` and `~rx_terminating`:
                                LET tr == chan_transfers[active_rx_cookie]
                                    hw_done == (tr.state \in {"CompletedHwCookieInProgress", "CompletedHw"})
                                    status_complete == (tr.state = "CompletedHw")
                                    pause_ret_nonzero ==
                                        \/ (hw_done /\ ALLOW_PAUSE_FAIL_ON_COMPLETE)
                                        \/ (~hw_done /\ pause_fails_active /\ ALLOW_PAUSE_FAIL_ACTIVE)
                                    goto_recover_before_copy ==
                                        /\ pause_ret_nonzero
                                        /\ ~status_complete
                                        /\ ~(HANDLE_HW_DONE_PAUSE_FAIL /\ hw_done)
                                    term_ret_nonzero ==
                                        /\ ~goto_recover_before_copy
                                        /\ terminate_async_fails
                                        /\ ALLOW_TERMINATE_ASYNC_FAIL
                                IN
                                IF goto_recover_before_copy
                                THEN \* `dmaengine_pause()` returned non-zero and `status != DMA_COMPLETE`
                                     \* -> jumps to `recover:` at 8250_dma.c:331 BEFORE `serial8250_rx_dma_copy()`!
                                     \* When `hw_done` is TRUE (`CompletedHwCookieInProgress`), up to 4 KB of
                                     \* hardware-received RX data in `dma->rx_buf` is discarded AND `dma->rx_err`
                                     \* is permanently latched (`spurious_rx_err = TRUE`)!
                                     /\ completed_rx_data_lost' = (completed_rx_data_lost \/ hw_done)
                                     /\ spurious_rx_err' = (spurious_rx_err \/ hw_done)
                                     /\ rx_err' = TRUE
                                     /\ rx_terminating' = TRUE
                                     /\ hw_ier_rx_enabled' = ComputeHwIerRx(ier_rdi_shadow, shutting_down, TRUE)
                                     /\ rx_flush_work_state' =
                                         IF rx_flush_work_state = "Idle" THEN "Pending" ELSE rx_flush_work_state
                                     /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow,
                                                    dma_attached, shutting_down, rx_running,
                                                    rx_flush_work_recover, next_transfer_id, active_rx_cookie,
                                                    chan_transfers, unhandled_rx_irq_storm>>
                                ELSE IF term_ret_nonzero
                                     THEN \* `serial8250_rx_dma_copy(p, &state)` copied the paused residue at
                                          \* line 338, set `dma->rx_terminating = true` at line 339, and then
                                          \* `dmaengine_terminate_async()` failed at line 340 -> jumps to `recover:`
                                          \* so `rx_flush_work` will run `dmaengine_terminate_sync()` in process
                                          \* context and unmask `UART_IER` for PIO fallback.
                                          /\ rx_err' = TRUE
                                          /\ rx_terminating' = TRUE
                                          /\ hw_ier_rx_enabled' = ComputeHwIerRx(ier_rdi_shadow, shutting_down, TRUE)
                                          /\ rx_flush_work_state' =
                                              IF rx_flush_work_state = "Idle" THEN "Pending" ELSE rx_flush_work_state
                                          /\ chan_transfers' = [chan_transfers EXCEPT
                                                ![active_rx_cookie].state =
                                                    IF tr.state = "Active" THEN "Paused" ELSE tr.state,
                                                ![active_rx_cookie].copy_count =
                                                    IF tr.copy_count < 2 THEN tr.copy_count + 1 ELSE 2]
                                          /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow,
                                                         dma_attached, shutting_down, rx_running,
                                                         rx_flush_work_recover, next_transfer_id, active_rx_cookie,
                                                         completed_rx_data_lost, spurious_rx_err,
                                                         unhandled_rx_irq_storm>>
                                     ELSE \* Both pause (or hardware completion) and `dmaengine_terminate_async()`
                                          \* succeeded: `serial8250_rx_dma_copy()` copies the buffer, sets
                                          \* `dma->rx_terminating = true`, `dma->rx_running = 0`, schedules
                                          \* `rx_flush_work`, and returns 0 so `serial8250_rx_chars()` drains
                                          \* any remaining bytes in the UART RX FIFO.
                                          /\ rx_terminating' = TRUE
                                          /\ rx_running' = FALSE
                                          /\ rx_flush_work_state' =
                                              IF rx_flush_work_state = "Idle" THEN "Pending" ELSE rx_flush_work_state
                                          /\ chan_transfers' = [chan_transfers EXCEPT
                                                ![active_rx_cookie].state =
                                                    IF tr.state \in {"Active", "CompletedHwCookieInProgress"}
                                                    THEN "TerminatedAsync"
                                                    ELSE "Retired",
                                                ![active_rx_cookie].copy_count =
                                                    IF tr.copy_count < 2 THEN tr.copy_count + 1 ELSE 2]
                                          /\ uart_fifo_has_data' = FALSE
                                          /\ UNCHANGED <<port_open, ier_rdi_shadow, hw_ier_rx_enabled,
                                                         dma_attached, shutting_down, rx_err,
                                                         rx_flush_work_recover, next_transfer_id,
                                                         active_rx_cookie, completed_rx_data_lost,
                                                         spurious_rx_err, unhandled_rx_irq_storm>>

\* 5a. serial8250_rx_dma_flush_work() step 1 (drivers/tty/serial/8250/8250_dma.c:142-163):
\*     Snapshots `recover = dma->rx_err` under `p->port.lock` (lines 150-151), then outside
\*     `p->port.lock` runs `dmaengine_terminate_sync(dma->rxchan)` (if `recover`) or
\*     `dmaengine_synchronize(dma->rxchan)` (if `!recover`).
RxFlushWorkStartSync ==
    /\ rx_flush_work_state = "Pending"
    /\ rx_flush_work_state' = "Running_Sync"
    /\ rx_flush_work_recover' = rx_err
    /\ chan_transfers' = [tid \in TransferIds |->
        LET tr == chan_transfers[tid] IN
        IF rx_err
        THEN [tr EXCEPT
                !.state = IF tr.state \in {"Active", "Paused", "CompletedHwCookieInProgress", "TerminatedAsync", "CompletedHw"}
                          THEN "Retired"
                          ELSE tr.state,
                !.callback_pending = FALSE]
        ELSE [tr EXCEPT
                !.state = IF HAS_DEVICE_SYNCHRONIZE /\ tr.state \in {"TerminatedAsync", "CompletedHw"}
                          THEN "Retired"
                          ELSE tr.state,
                !.callback_pending = IF HAS_DEVICE_SYNCHRONIZE THEN FALSE ELSE tr.callback_pending]]
    /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow, hw_ier_rx_enabled,
                   dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                   next_transfer_id, active_rx_cookie,
                   completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>

\* 5b. serial8250_rx_dma_flush_work() step 2 (drivers/tty/serial/8250/8250_dma.c:166-177):
\*     Acquires `scoped_guard(uart_port_lock_irqsave, &p->port)`, sets:
\*       dma->rx_terminating = false;
\*       dma->rx_running = 0;
\*       if (dma->shutting_down)
\*           return;
\*       if (recover)
\*           serial8250_out_IER(p, p->ier);
RxFlushWorkFinishLocked ==
    /\ rx_flush_work_state = "Running_Sync"
    /\ rx_flush_work_state' = "Idle"
    /\ rx_terminating' = FALSE
    /\ rx_running' = FALSE
    /\ active_rx_cookie' = 0
    /\ hw_ier_rx_enabled' =
        IF ~shutting_down /\ rx_flush_work_recover
        THEN ComputeHwIerRx(ier_rdi_shadow, shutting_down, FALSE)
        ELSE hw_ier_rx_enabled
    /\ rx_flush_work_recover' = FALSE
    /\ UNCHANGED <<port_open, uart_fifo_has_data, ier_rdi_shadow,
                   dma_attached, shutting_down, rx_err, next_transfer_id,
                   chan_transfers, completed_rx_data_lost, spurious_rx_err,
                   unhandled_rx_irq_storm>>

\* 6. Port Shutdown:
\*    serial8250_do_shutdown() (8250_port.c:2484-2532)
\*    -> serial8250_release_dma() (8250_dma.c:470-505):
\*      Sets `dma->shutting_down = true`, masks `UART_IER`, calls
\*      `disable_work_sync(&dma->rx_flush_work)` and `dmaengine_terminate_sync(dma->rxchan)`,
\*      and under `port->lock` clears `dma->rx_running = 0`, `dma->rx_terminating = false`.
PortShutdown ==
    /\ port_open
    /\ port_open' = FALSE
    /\ shutting_down' = TRUE
    /\ ier_rdi_shadow' = FALSE
    /\ hw_ier_rx_enabled' = FALSE
    /\ rx_flush_work_state' = "Idle"
    /\ rx_flush_work_recover' = FALSE
    /\ rx_running' = FALSE
    /\ rx_terminating' = FALSE
    /\ active_rx_cookie' = 0
    /\ chan_transfers' = [tid \in TransferIds |->
        [chan_transfers[tid] EXCEPT
            !.state = IF chan_transfers[tid].state \in {"Active", "Paused", "CompletedHwCookieInProgress", "TerminatedAsync", "CompletedHw"}
                      THEN "Retired"
                      ELSE chan_transfers[tid].state,
            !.callback_pending = FALSE]]
    /\ UNCHANGED <<uart_fifo_has_data, dma_attached, rx_err,
                   next_transfer_id, completed_rx_data_lost,
                   spurious_rx_err, unhandled_rx_irq_storm>>

\* 7. Port Reopen:
\*    serial8250_do_startup() (drivers/tty/serial/8250/8250_port.c:2291-2467):
\*      - Under `port->lock`, sets `up->dma->shutting_down = false` (line 2417).
\*      - Calls `serial8250_request_dma(up)` (line 2418):
\*          * If it succeeds (`request_dma_succeeds = TRUE`), `serial8250_request_dma()`
\*            resets `dma->rx_running = 0`, `dma->rx_terminating = false`, `dma->rx_err = false`,
\*            `dma->shutting_down = false` (8250_dma.c:434-439).
\*          * If it fails with `-ENODEV` (`request_dma_succeeds = FALSE`), line 2419 sets
\*            `up->dma = NULL` (`dma_attached' = FALSE`) so the port falls back to pure PIO.
PortReopen(request_dma_succeeds) ==
    /\ ~port_open
    /\ (request_dma_succeeds \/ ALLOW_REOPEN_WITHOUT_DMA)
    /\ port_open' = TRUE
    /\ uart_fifo_has_data' = TRUE
    /\ ier_rdi_shadow' = TRUE
    /\ shutting_down' = FALSE
    /\ dma_attached' = IF request_dma_succeeds THEN dma_attached ELSE FALSE
    /\ rx_err' = IF request_dma_succeeds THEN FALSE ELSE rx_err
    /\ hw_ier_rx_enabled' = ComputeHwIerRx(TRUE, FALSE, FALSE)
    /\ UNCHANGED <<rx_running, rx_terminating,
                   rx_flush_work_state, rx_flush_work_recover,
                   next_transfer_id, active_rx_cookie, chan_transfers,
                   completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>

\* 8. New bytes arrive in UART hardware RX FIFO:
UartRxFifoArrive ==
    /\ port_open
    /\ ~uart_fifo_has_data
    /\ uart_fifo_has_data' = TRUE
    /\ UNCHANGED <<port_open, ier_rdi_shadow, hw_ier_rx_enabled,
                   dma_attached, shutting_down, rx_running, rx_terminating, rx_err,
                   rx_flush_work_state, rx_flush_work_recover,
                   next_transfer_id, active_rx_cookie, chan_transfers,
                   completed_rx_data_lost, spurious_rx_err, unhandled_rx_irq_storm>>

Next ==
    \/ StartRxDma
    \/ \E tid \in TransferIds : DmaRxHwFinishBeforeCookieUpdate(tid)
    \/ \E tid \in TransferIds : DmaRxHwComplete(tid)
    \/ \E tid \in TransferIds : DmaRxCompleteCallback(tid)
    \/ \E is_to \in {TRUE, FALSE}, pf_act \in {TRUE, FALSE}, tf \in {TRUE, FALSE} :
        UartRxIrq(is_to, pf_act, tf)
    \/ RxFlushWorkStartSync
    \/ RxFlushWorkFinishLocked
    \/ PortShutdown
    \/ \E req_ok \in {TRUE, FALSE} : PortReopen(req_ok)
    \/ UartRxFifoArrive

\* =========================================================================
\* Safety Invariants
\* =========================================================================

TypeOK ==
    /\ port_open \in BOOLEAN
    /\ uart_fifo_has_data \in BOOLEAN
    /\ ier_rdi_shadow \in BOOLEAN
    /\ hw_ier_rx_enabled \in BOOLEAN
    /\ dma_attached \in BOOLEAN
    /\ shutting_down \in BOOLEAN
    /\ rx_running \in BOOLEAN
    /\ rx_terminating \in BOOLEAN
    /\ rx_err \in BOOLEAN
    /\ rx_flush_work_state \in {"Idle", "Pending", "Running_Sync"}

\* INVARIANT 1: No RX Buffer Aliasing
\*   At most one RX DMA transfer may be unretired (`Active`, `Paused`,
\*   `CompletedHwCookieInProgress`, or `TerminatedAsync`) on the shared
\*   `dma->rx_buf` at any time.
NoRxBufferAliasing ==
    \A t1, t2 \in TransferIds :
        (chan_transfers[t1].state \in {"Active", "Paused", "CompletedHwCookieInProgress"} /\
         chan_transfers[t2].state \in {"Active", "Paused", "CompletedHwCookieInProgress"})
            => (t1 = t2)

\* INVARIANT 2: No Double RX Buffer Copy
\*   No RX DMA transfer's buffer may be copied to the TTY flip buffer more than once.
NoDoubleRxCopy ==
    \A tid \in TransferIds : chan_transfers[tid].copy_count <= 1

\* INVARIANT 3: No Unhandled RX Interrupt Storm
\*   The UART RX interrupt must never be skipped (`skip_rx = true`) while
\*   `UART_IER_RDI` remains unmasked in the hardware `UART_IER` register.
NoUnhandledRxIrqStorm ==
    ~unhandled_rx_irq_storm

\* INVARIANT 4: No Silent Data Loss on Hardware-Completed RX DMA Transfer
\*   A hardware-completed RX DMA buffer (up to 4 KB in `dma->rx_buf`) must never
\*   be discarded by jumping to `recover:` before `serial8250_rx_dma_copy()`.
NoCompletedRxDataLost ==
    ~completed_rx_data_lost

\* INVARIANT 5: No Spurious Permanent RX DMA Disablement on Normal Completion
\*   `dma->rx_err` must never be permanently latched when hardware already finished
\*   the RX DMA transfer normally (without an active-transfer pause failure or
\*   `dmaengine_terminate_async()` failure).
NoSpuriousPermanentRxErr ==
    ~spurious_rx_err

=============================================================================
