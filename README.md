# TLA+ models for Linux 8250 UART DMA cancellation

## Updated lifetime models (2026-10-28)

Run `bash run_lifetime.sh` for the audited model variants. See
[MODEL-NOTES.md](MODEL-NOTES.md) for code mappings, explicit assumptions,
bounded results and unresolved cases. The runner preserves counterexamples
in a unique directory instead of deleting trace files from this checkout.

The updated models use actual FIFO positions, separate hardware completion
from cookie updates, preserve detached callbacks through shutdown, and check
explicit progress properties. They also cover classic DW status-query
reentrancy and the OMAP shutdown admission window.

**The original review below is retained as historical material.** Its passing
`Fixed` configurations do not validate the proposed C fixes: the TX model
omits status-query callback reentrancy and idealizes teardown, while the RX
variant uses hardware-completion knowledge unavailable to the generic driver.
Some cited RX providers also do not reach that generic finite-transfer path.
The original `run_tlc.sh` removes trace files from the checkout; use the new
runner for the updated suite.

## Archived v7 review and original models

This repository contains formal TLA+ specifications and TLC model-checking configurations for the Linux kernel `8250` UART TX/RX DMA cancellation and buffer-reuse state machines introduced in:

* **Series**: `[PATCH v7 0/5] serial: 8250: serialize DMA cancellation with buffer reuse`
* **Author**: James Hilliard `<james.hilliard1@gmail.com>`
* **Patches modeled**:
  1. `[PATCH v7 1/5] serial: 8250_omap: separate locked TX DMA completion processing` (`drivers/tty/serial/8250/8250_omap.c`)
  2. `[PATCH v7 2/5] serial: serialize asynchronous write wakeups with the port lock` (`drivers/tty/serial/serial_core.c`)
  3. `[PATCH v7 3/5] serial: core: allow drivers to reserve flushed transmit storage` (`include/linux/serial_core.h`, `drivers/tty/serial/serial_core.c`)
  4. `[PATCH v7 4/5] serial: 8250: drain canceled TX DMA before reusing its buffer` (`drivers/tty/serial/8250/8250.h`, `8250_dma.c`, `8250_port.c`)
  5. `[PATCH v7 5/5] serial: 8250: retire canceled RX DMA before reusing the receive buffer` (`drivers/tty/serial/8250/8250.h`, `8250_dma.c`, `8250_port.c`)

---

## Quick Start (One-Command Local Reproduction)

Prerequisites: `java` (JDK 11+) and `curl`. The runner script automatically downloads `tla2tools.jar` (`v1.8.0`) if not already present:

```bash
./run_tlc.sh
```

Or run an individual configuration directly with TLC:

```bash
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC \
    -config Serial8250TxDmaV7_NoSync.cfg Serial8250TxDmaV7.tla
```

---

## Configuration Matrix & TLC Verification Summary

| Model | Configuration (`.cfg`) | DMA / Hardware Environment | Mode (`v7` vs Fix) | Expected TLC Result | States Generated / Distinct |
| :--- | :--- | :--- | :--- | :--- | :--- |
| [`Serial8250TxDmaV7.tla`](Serial8250TxDmaV7.tla) | [`Serial8250TxDmaV7_Ideal.cfg`](Serial8250TxDmaV7_Ideal.cfg) | `.device_synchronize` implemented (`HAS_DEVICE_SYNCHRONIZE = TRUE`), plus shutdown, suspend/resume, and close-while-suspended | `v7` as posted (`CHECK_TX_STATUS_IN_CALLBACK = FALSE`) | **PASS (`0` errors)** | 3,142 / 736 (depth 15) |
| [`Serial8250TxDmaV7.tla`](Serial8250TxDmaV7.tla) | [`Serial8250TxDmaV7_NoSync.cfg`](Serial8250TxDmaV7_NoSync.cfg) | `.device_synchronize == NULL` (`HAS_DEVICE_SYNCHRONIZE = FALSE`, `MAX_TRANSFERS = 1`, e.g. `sun6i-dma`, `dw_dmac`, `pl330`, `mtk-uart-apdma`) | `v7` as posted (`CHECK_TX_STATUS_IN_CALLBACK = FALSE`) | **FAIL: `NoStaleCallbackCorruption` violated** (7-state trace) | 111 / 51 (depth 7) |
| [`Serial8250TxDmaV7.tla`](Serial8250TxDmaV7.tla) | [`Serial8250TxDmaV7_NoSync_Fixed.cfg`](Serial8250TxDmaV7_NoSync_Fixed.cfg) | `.device_synchronize == NULL` (`HAS_DEVICE_SYNCHRONIZE = FALSE`, `MAX_TRANSFERS = 1`) | **Proposed Fix (`CHECK_TX_STATUS_IN_CALLBACK = TRUE`)** | **PASS (`0` errors)** | 438 / 146 (depth 12) |
| [`Serial8250TxDmaV7.tla`](Serial8250TxDmaV7.tla) | [`Serial8250TxDmaV7_NoSync_BufferAliasing.cfg`](Serial8250TxDmaV7_NoSync_BufferAliasing.cfg) | `.device_synchronize == NULL` (`HAS_DEVICE_SYNCHRONIZE = FALSE`, `MAX_TRANSFERS = 2`) | `v7` as posted (`CHECK_TX_STATUS_IN_CALLBACK = FALSE`) | **FAIL: `NoBufferAliasing` violated** (10-state trace) | 569 / 260 (depth 10) |
| [`Serial8250TxDmaV7.tla`](Serial8250TxDmaV7.tla) | [`Serial8250TxDmaV7_NoSync_BufferAliasing_Fixed.cfg`](Serial8250TxDmaV7_NoSync_BufferAliasing_Fixed.cfg) | `.device_synchronize == NULL` (`HAS_DEVICE_SYNCHRONIZE = FALSE`, `MAX_TRANSFERS = 2`, plus shutdown & suspend/resume) | **Proposed Fix (`CHECK_TX_STATUS_IN_CALLBACK = TRUE`)** | **PASS (`0` errors)** | 9,944 / 1,814 (depth 19) |
| [`Serial8250RxDmaV7.tla`](Serial8250RxDmaV7.tla) | [`Serial8250RxDmaV7_Ideal.cfg`](Serial8250RxDmaV7_Ideal.cfg) | Standard DMA engine with active pause failure, `terminate_async` failure recovery, and reopen-without-DMA (`-ENODEV`) | `v7` as posted (`HANDLE_HW_DONE_PAUSE_FAIL = FALSE`) | **PASS (`0` errors)** | 746 / 164 (depth 10) |
| [`Serial8250RxDmaV7.tla`](Serial8250RxDmaV7.tla) | [`Serial8250RxDmaV7_HwDoneBeforeIrq.cfg`](Serial8250RxDmaV7_HwDoneBeforeIrq.cfg) | Hardware finishes RX transfer before DMA hardirq updates `completed_cookie` (`dw-axi-dmac`, `tegra210-adma`, `ti/omap-dma`) | `v7` as posted (`HANDLE_HW_DONE_PAUSE_FAIL = FALSE`) | **FAIL: `NoCompletedRxDataLost` & `NoSpuriousPermanentRxErr` violated** (4-state trace) | 29 / 11 (depth 4) |
| [`Serial8250RxDmaV7.tla`](Serial8250RxDmaV7.tla) | [`Serial8250RxDmaV7_HwDoneBeforeIrq_Fixed.cfg`](Serial8250RxDmaV7_HwDoneBeforeIrq_Fixed.cfg) | All RX failure modes enabled simultaneously (`ALLOW_PAUSE_FAIL_ON_COMPLETE`, `ALLOW_HW_DONE_COOKIE_IN_PROGRESS`, `ALLOW_PAUSE_FAIL_ACTIVE`, `ALLOW_TERMINATE_ASYNC_FAIL`, `ALLOW_REOPEN_WITHOUT_DMA`) | **Proposed Fix (`HANDLE_HW_DONE_PAUSE_FAIL = TRUE`)** | **PASS (`0` errors)** | 812 / 176 (depth 10) |

---

## Detailed Findings & Counterexample Traces

### 1. TX DMA (`[PATCH v7 1/5]` & `[PATCH v7 4/5]`): Stale Completion Callback on DMA Engines Without `.device_synchronize`

In `[PATCH v7 4/5]` (`drivers/tty/serial/8250/8250_dma.c:40-50`) and `[PATCH v7 1/5]` (`drivers/tty/serial/8250/8250_omap.c:1126-1136`), `__dma_tx_complete()` and `omap_8250_dma_tx_complete()` removed `if (!dma->tx_running) return;` and only check `if (serial8250_tx_dma_blocked(dma)) return;`:

```c
static void __dma_tx_complete(void *param)
{
	struct uart_8250_port *p = param;
	struct uart_8250_dma *dma = p->dma;

	scoped_guard(uart_port_lock_irqsave, &p->port) {
		if (serial8250_tx_dma_blocked(dma))
			return;

		serial8250_tx_dma_complete(p);
	}
}
```

Unlike `dma_rx_complete()` (`8250_dma.c:125-135`), which checks both `if (dma->rx_running)` and `dmaengine_tx_status(dma->rxchan, dma->rx_cookie, &state) == DMA_COMPLETE`, the TX completion callbacks check neither.

On DMA controllers that do **not** implement `.device_synchronize` (such as `sun6i-dma`, `dw_dmac`, `pl330`, and `mtk-uart-apdma`), `dmaengine_synchronize(dma->txchan)` in `serial8250_tx_dma_flush_work()` is a no-op (`drivers/dma/dmaengine.h:1164-1169`).

#### Counterexample 1a (`Serial8250TxDmaV7_NoSync.cfg` — `NoStaleCallbackCorruption` violated in 7 states)
1. **State 1 (`Init`)**: `xmit_fifo_count = 1`.
2. **State 2 (`StartTxDma`)**: Transfer #1 starts (`active_cookie_id = 1`, `tx_running = TRUE`).
3. **State 3 (`DmaHwComplete(1)`)**: Hardware finishes Transfer #1 just as `uart_flush_buffer()` runs; the completion tasklet is scheduled (`callback_pending = TRUE`).
4. **State 4 (`UartFlushBuffer(TRUE)`)**: `serial8250_tx_dma_flush()` sets `xmit_blocked = TRUE`, `tx_flushed = TRUE`, `tx_terminating = TRUE`, and schedules `tx_flush_work`.
5. **State 5 (`TxFlushWorkStartSync`)**: `dmaengine_synchronize()` is a no-op (`HAS_DEVICE_SYNCHRONIZE = FALSE`).
6. **State 6 (`TxFlushWorkFinishLocked`)**: `tx_flush_work` clears `tx_terminating = FALSE`, `tx_running = FALSE`, unblocks `xmit_blocked = FALSE`, and sets `ier_thri = TRUE`.
7. **State 7 (`DmaTxCompleteCallback(1)`)**: The delayed tasklet from Transfer #1 runs. Because `tx_terminating` is now `FALSE`, `serial8250_tx_dma_blocked(dma)` is `FALSE`, so `__dma_tx_complete()` executes `serial8250_tx_dma_complete(p)` while `tx_running == 0` (`stale_cb_corrupted = TRUE`).

#### Counterexample 1b (`Serial8250TxDmaV7_NoSync_BufferAliasing.cfg` — `NoBufferAliasing` violated in 10 states)
If `uart_write()` queues a segment into `xmit_fifo` (`State 7: UartWrite` -> `State 8: StartTxDma` for Transfer #2, `active_cookie_id = 2`, `state = "Active"`, `buf_epoch = 2`) after `tx_flush_work` unblocks the port in State 6, and then the stale callback from Transfer #1 fires (`State 9: DmaTxCompleteCallback(1)`):
* `__dma_tx_complete()` calls `serial8250_tx_dma_complete(p)` while Transfer #2 is still `Active` in hardware.
* `serial8250_tx_dma_complete(p)` pops Transfer #2's unsent bytes from `xmit_fifo` (`uart_xmit_advance(&p->port, dma->tx_size)` -> `xmit_fifo_count = 0`) and clears `tx_running = 0` while Transfer #2 is still `Active` on `dma->txchan`!
* A subsequent `uart_write()` (`State 10: UartWrite`) writes at offset 0 of `xmit_buf` (`xmit_buf_epoch = 3`) while Transfer #2 (`buf_epoch = 2`) is still actively reading `xmit_buf` via DMA (`NoBufferAliasing` violated).

#### Proposed Fix (`CHECK_TX_STATUS_IN_CALLBACK = TRUE`)
Guard `__dma_tx_complete()` and `omap_8250_dma_tx_complete()` with `dma->tx_running` and `dmaengine_tx_status(dma->txchan, dma->tx_cookie, NULL) == DMA_COMPLETE` (matching `dma_rx_complete()`):

```c
	scoped_guard(uart_port_lock_irqsave, &p->port) {
		if (serial8250_tx_dma_blocked(dma) || !dma->tx_running)
			return;
		if (dmaengine_tx_status(dma->txchan, dma->tx_cookie, NULL) != DMA_COMPLETE)
			return;

		serial8250_tx_dma_complete(p);
	}
```

Setting `CHECK_TX_STATUS_IN_CALLBACK = TRUE` in [`Serial8250TxDmaV7_NoSync_Fixed.cfg`](Serial8250TxDmaV7_NoSync_Fixed.cfg) and [`Serial8250TxDmaV7_NoSync_BufferAliasing_Fixed.cfg`](Serial8250TxDmaV7_NoSync_BufferAliasing_Fixed.cfg) passes TLC with **`0` errors** across all 9,944 generated / 1,814 distinct states.

---

### 2. RX DMA (`[PATCH v7 5/5]`): Silent Data Loss & Permanent RX DMA Disablement When Hardware Completes Before Cookie Update

In `[PATCH v7 5/5]` (`drivers/tty/serial/8250/8250_dma.c:325-336`), `serial8250_rx_dma_flush()` executes:

```c
	ret = dmaengine_pause(dma->rxchan);
	status = dmaengine_tx_status(dma->rxchan, dma->rx_cookie, &state);
	if (ret && status != DMA_COMPLETE)
		goto recover;
	if (status == DMA_ERROR) {
		ret = -EIO;
		goto recover;
	}

	serial8250_rx_dma_copy(p, &state);
```

This assumes that if the DMA hardware has already completed the RX buffer transfer causing `dmaengine_pause()` to return an error (e.g. `-EAGAIN` on `dw-axi-dmac` in `drivers/dma/dw-axi-dmac/dw-axi-dmac-platform.c:1244-1274` because `DMAC_CHEN` already self-cleared so `DWAXIDMAC_IRQ_SUSPENDED` never sets), `dmaengine_tx_status()` will return `DMA_COMPLETE`.

However, `dmaengine_tx_status()` only returns `DMA_COMPLETE` **after** the DMA controller's interrupt handler calls `dma_cookie_complete()` / `vchan_cookie_complete()`:
1. **`dw-axi-dmac` (`dw-axi-dmac-platform.c:356-388, 1158-1267`)**: `serial8250_handle_irq_locked()` holds `p->port.lock` with local interrupts disabled (`uart_port_lock_irqsave`). If the RX DMA transfer finishes in hardware before `dw_axi_dma_interrupt()` runs `vchan_cookie_complete()`, hardware clears `CH_EN` in `DMAC_CHEN`, so `dma_chan_pause()` times out after 20 iterations (`40 us`) waiting for `DWAXIDMAC_IRQ_SUSPENDED` and returns `-EAGAIN`, while `dma_chan_tx_status()` still returns `DMA_IN_PROGRESS` (and reports `state.residue = length` for non-cyclic transfers until `dw_axi_dma_interrupt()` runs).
2. **`tegra210-adma` (`drivers/dma/tegra210-adma.c:696`) & `ti/omap-dma` (`drivers/dma/ti/omap-dma.c:513-514`)**: `tegra_adma_pause()` returns `-EBUSY` and `omap_dma_pause()` returns `-EINVAL` if the hardware channel cleared `CCR_ENABLE` before the DMA ISR ran `vchan_cookie_complete()`, while `dma_cookie_status()` still returns `DMA_IN_PROGRESS`.

#### Counterexample 2 (`Serial8250RxDmaV7_HwDoneBeforeIrq.cfg` — `NoCompletedRxDataLost` & `NoSpuriousPermanentRxErr` violated in 4 states)
1. **State 1 (`Init`)**: Port open, RX FIFO has data.
2. **State 2 (`StartRxDma`)**: Transfer #1 is `Active`.
3. **State 3 (`DmaRxHwFinishBeforeCookieUpdate(1)`)**: Hardware finishes writing the RX DMA buffer (`state.residue == 0`), but the DMA IRQ/tasklet has not yet updated `chan->completed_cookie` (`CompletedHwCookieInProgress`).
4. **State 4 (`UartRxIrq(TRUE, FALSE, FALSE)`)**: UART RX timeout interrupt calls `serial8250_rx_dma_flush()`. `dmaengine_pause()` returns non-zero (`-EAGAIN`) and `dmaengine_tx_status()` returns `DMA_IN_PROGRESS` (`status != DMA_COMPLETE`). `serial8250_rx_dma_flush()` jumps to `recover:` **before** `serial8250_rx_dma_copy()`, silently discarding the entire completed RX buffer (`completed_rx_data_lost = TRUE`) and latching `dma->rx_err = true` for the lifetime of the open port (`spurious_rx_err = TRUE`).

*(Note: Setting `HANDLE_HW_DONE_PAUSE_FAIL = TRUE` in [`Serial8250RxDmaV7_HwDoneBeforeIrq_Fixed.cfg`](Serial8250RxDmaV7_HwDoneBeforeIrq_Fixed.cfg) models handling a hardware-completed transfer before jumping to `recover:`, which passes TLC with **`0` errors** across all 812 generated / 176 distinct states.)*
