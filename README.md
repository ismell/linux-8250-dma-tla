# TLA+ Formal Models for Linux 8250 UART DMA Cancellation (`[PATCH v8 0/6]` & `[PATCH v7 0/5]`)

This repository contains formal TLA+ specifications and TLC model-checking configurations for the Linux kernel `8250` UART TX/RX DMA cancellation, flush workqueue, and buffer-reuse state machines introduced by James Hilliard (`<james.hilliard1@gmail.com>`).

---

## Quick Start (One-Command Local Reproduction)

Prerequisites: `java` (JDK 11+) and `curl`. The runner scripts automatically download `tla2tools.jar` (`v1.8.0`) if not already present:

```bash
# Run all 21 configurations (8 v7 + 13 v8):
./run_tlc.sh

# Or run only the 13 v8 configurations:
./run_v8.sh
```

Run an individual configuration directly with TLC:

```bash
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC \
    -config Serial8250RxDmaV8_PartialTransferPauseFails.cfg Serial8250RxDmaV8.tla
```

---

## 1. `[PATCH v8 0/6]` Configuration Matrix & TLC Verification Summary (13 Configs)

Patches modeled in [`Serial8250RxDmaV8.tla`](Serial8250RxDmaV8.tla) and [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla):
1. `[PATCH v8 1/6] serial: 8250_omap: separate locked TX DMA completion processing` (`drivers/tty/serial/8250/8250_omap.c`)
2. `[PATCH v8 2/6] serial: serialize asynchronous write wakeups with the port lock` (`drivers/tty/serial/serial_core.c`)
3. `[PATCH v8 3/6] serial: core: allow drivers to reserve flushed transmit storage` (`include/linux/serial_core.h`, `drivers/tty/serial/serial_core.c`)
4. `[PATCH v8 4/6] serial: 8250: drain canceled TX DMA before reusing its buffer` (`drivers/tty/serial/8250/8250.h`, `8250_dma.c`, `8250_port.c`)
5. `[PATCH v8 5/6] serial: 8250: retire canceled RX DMA before reusing the receive buffer` (`drivers/tty/serial/8250/8250.h`, `8250_dma.c`, `8250_port.c`, `8250_dw.c`)
6. `[PATCH v8 6/6] serial: 8250: retain DMA resources when termination fails` (`drivers/tty/serial/8250/8250_dma.c`, `8250_omap.c`, `8250_port.c`)

| Model | Configuration (`.cfg`) | DMA / Hardware Environment | Mode (`v8` vs Fix) | Expected TLC Result | States Generated / Distinct |
| :--- | :--- | :--- | :--- | :--- | :--- |
| [`Serial8250RxDmaV8.tla`](Serial8250RxDmaV8.tla) | [`Serial8250RxDmaV8_Ideal.cfg`](Serial8250RxDmaV8_Ideal.cfg) | Standard DMA engine (`dmaengine_pause() == 0`, `.device_synchronize` implemented) | `v8` as posted | **PASS (`0` errors)** | 121 / 71 (depth 10) |
| [`Serial8250RxDmaV8.tla`](Serial8250RxDmaV8.tla) | [`Serial8250RxDmaV8_HwDoneBeforeIrq.cfg`](Serial8250RxDmaV8_HwDoneBeforeIrq.cfg) | Hardware finishes full RX transfer (`hw_state = "completed"`) before DMA hardirq updates `completed_cookie` (`PauseFailsWhenHwCompleted = TRUE`) | `v8` as posted (`rx_pause_pending` retry waits for `DmaIrq`) | **PASS (`0` errors)** — `v7` data-loss bug fixed | 347 / 173 (depth 15) |
| [`Serial8250RxDmaV8.tla`](Serial8250RxDmaV8.tla) | [`Serial8250RxDmaV8_RecoverFallback.cfg`](Serial8250RxDmaV8_RecoverFallback.cfg) | `DMA_ERROR`, `PauseFailsWhenHwCompleted = TRUE`, `dmaengine_terminate_async()` / `dmaengine_terminate_sync()` failures (`AllowTerminateFailure = TRUE`), and port shutdown (`AllowClose = TRUE`) | `v8` as posted | **PASS (`0` errors)** | 1,437 / 480 (depth 16) |
| [`Serial8250RxDmaV8.tla`](Serial8250RxDmaV8.tla) | [`Serial8250RxDmaV8_PartialTransferPauseFails.cfg`](Serial8250RxDmaV8_PartialTransferPauseFails.cfg) | Partial RX burst (`hw_bytes = 1 < RxSize`, `peer_done = TRUE`) on DMA engine where `dmaengine_pause()` returns `-ENXIO` (`PauseFailsWhenHwActive = TRUE`, `PauseSucceedsOnRetry = FALSE`) | `v8` as posted (`BoundPauseRetries = FALSE`) | **FAIL: `WorkerBoundedRetries` violated** (9-state trace) | 35 / 30 (depth 9) |
| [`Serial8250RxDmaV8.tla`](Serial8250RxDmaV8.tla) | [`Serial8250RxDmaV8_PartialTransferPauseFails_Fixed.cfg`](Serial8250RxDmaV8_PartialTransferPauseFails_Fixed.cfg) | Both `PauseFailsWhenHwCompleted = TRUE` and `PauseFailsWhenHwActive = TRUE` (`PauseSucceedsOnRetry = FALSE`) | **Proposed Fix (`BoundPauseRetries = TRUE`)**: bounded retry escalates to `serial8250_rx_dma_recover()` | **PASS (`0` errors)** (`FlushWorkProgress` & `NoCompletedRxDataLost` hold) | 74 / 54 (depth 11) |
| [`Serial8250RxDmaV8.tla`](Serial8250RxDmaV8.tla) | [`Serial8250RxDmaV8_DwIdleEnterDuringPausePending.cfg`](Serial8250RxDmaV8_DwIdleEnterDuringPausePending.cfg) | `dw8250_set_divisor()` -> `dw8250_idle_enter()` called while `rx_pause_pending = TRUE` (`AllowDwSetDivisor = TRUE`) | `v8` as posted | **FAIL: `NoAbortedDivisorProgramming` violated** (5-state trace) | 11 / 11 (depth 5) |
| [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla) | [`Serial8250TxDmaV8_Ideal.cfg`](Serial8250TxDmaV8_Ideal.cfg) | `.device_synchronize` implemented (`DrainCallbacksOnSync = TRUE`), plus `uart_flush_buffer()`, `tty_wait_until_sent()`, and `uart_close()` | `v8` as posted (`CheckTxRunning = TRUE`) | **PASS (`0` errors)** (`ReservationProgress` & `ShutdownProgress` hold) | 16,409 / 7,085 (depth 28) |
| [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla) | [`Serial8250TxDmaV8_NoSync_ActiveTransferAliasing.cfg`](Serial8250TxDmaV8_NoSync_ActiveTransferAliasing.cfg) | `.device_synchronize == NULL` (`DrainCallbacksOnSync = FALSE`, `MaxTransfers = 3`) | `v8` as posted (`CheckTxRunning = TRUE`, `CheckTxCookieStatus = FALSE`) | **FAIL: `NoBufferAliasing` violated** (13-state trace) | 628 / 352 (depth 13) |
| [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla) | [`Serial8250TxDmaV8_NoSync_Fixed.cfg`](Serial8250TxDmaV8_NoSync_Fixed.cfg) | `.device_synchronize == NULL` (`DrainCallbacksOnSync = FALSE`, `MaxTransfers = 3`, `AllowClose = FALSE`) | **Proposed Fix (`CheckTxCookieStatus = TRUE`)**: check `dmaengine_tx_status(txchan, tx_cookie, NULL) == DMA_COMPLETE` | **PASS (`0` errors)** | 7,170 / 2,885 (depth 25) |
| [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla) | [`Serial8250TxDmaV8_LostFlushWakeup.cfg`](Serial8250TxDmaV8_LostFlushWakeup.cfg) | `tty_wait_until_sent()` sleeper (`wait_until_sent_sleeping = TRUE`) races with `uart_flush_buffer()` + `uart_close()` (`serial8250_release_dma()`) | `v8` as posted (`FlushWakesWriteWaitDirectly = FALSE`) | **FAIL: `NoLostFlushWaiterWakeup` violated** (9-state trace) | 285 / 204 (depth 9) |
| [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla) | [`Serial8250TxDmaV8_LostFlushWakeup_Fixed.cfg`](Serial8250TxDmaV8_LostFlushWakeup_Fixed.cfg) | `tty_wait_until_sent()` sleeper races with `uart_flush_buffer()` + `uart_close()` | **Proposed Fix (`FlushWakesWriteWaitDirectly = TRUE`)** | **PASS (`0` errors)** | 2,258 / 1,210 (depth 21) |
| [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla) | [`Serial8250TxDmaV8_TerminateRetryHang.cfg`](Serial8250TxDmaV8_TerminateRetryHang.cfg) | `dmaengine_terminate_sync()` returns persistent error during `serial8250_terminate_dma()` (`AllowTerminateFailure = TRUE`) | `v8` as posted (`Patch6RetryOnTerminateFailure = TRUE`, `QuarantineOnTerminateFailure = FALSE`) | **FAIL: `BoundedTerminateRetries` violated** (5-state trace) | 38 / 28 (depth 5) |
| [`Serial8250TxDmaV8.tla`](Serial8250TxDmaV8.tla) | [`Serial8250TxDmaV8_TerminateRetryHang_Fixed.cfg`](Serial8250TxDmaV8_TerminateRetryHang_Fixed.cfg) | `dmaengine_terminate_sync()` returns persistent error during `serial8250_terminate_dma()` (`AllowTerminateFailure = TRUE`) | **Proposed Fix (`QuarantineOnTerminateFailure = TRUE`)**: quarantine channel & retain DMA buffers on shutdown | **PASS (`0` errors)** (`NoUsersAtFree`, `BoundedTerminateRetries`, `ShutdownProgress` hold) | 5,547 / 2,478 (depth 22) |

---

## 2. `[PATCH v7 0/5]` Configuration Matrix & TLC Verification Summary (8 Configs)

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
