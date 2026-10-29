# DMA cancellation model-to-code audit

These are bounded executable models, not a proof of the Linux implementation
or of a particular controller's hardware behavior. The original v7 models and
configs remain unchanged for reproducing the review. Their passing `Fixed`
configs are **not** evidence that the suggested C fixes are safe.

## Reproduction

Run `bash run_lifetime.sh`. The runner uses an existing `tla2tools.jar`, or
`TLA2TOOLS_JAR`, and verifies this SHA-256:

```
fc6878c603f0fdc18b9fe3e5bf51860cb90ab5b1154e3c371660c036d6bdd63e
```

This is the installed v1.8.0 TLC build, revision `56d37a9`. The runner uses
one worker, a 2 GiB heap, seed 1 and fingerprint index 0. It copies inputs to
a unique directory under `TMPDIR` (default `/tmp`), records their hashes, and
retains logs, traces and state files. It never deletes checkout files. An
expected invariant violation must have TLC exit status 12 and name the
specified invariant; a parser error or JVM failure is not an expected failure.

## Reference implementation

The baseline is the sent v7 kernel tree
`7bfb5df6c2271b2f6680372feb81f180a05d95b0`. The draft v8 inspected here is
`402915fc288c` on `submit/serial-8250-dma-cancel-v8`. The original model revision
is `ab9e5bcda2b884b181571305554d8d47bc053573`.

| Model action/state | Kernel meaning |
|---|---|
| TX `Write`, `input`, `output`, `mem` | `uart_write()` / kfifo monotonic counters and modulo buffer positions |
| TX `Start`, `Complete` | `serial8250_tx_dma()` and locked `serial8250_tx_dma_complete()` |
| TX `Flush` | Port-locked FIFO reset, reservation and `serial8250_tx_dma_flush()` |
| TX `WorkerBegin/Sync/Finish` | Flush worker's synchronization outside the port lock, then locked retirement |
| TX `Capture/Enter/Invoke/Return` | Provider detaches a callback, enters it, runs its port-locked body, and returns |
| TX close phases | Admission gate, work cancellation, termination, synchronization, unmap/free |
| RX `Receive`, `Irq`, `ReportedCount` | Physical data arrival, later cookie completion, and provider-visible residue |
| RX `Flush` | Generic `serial8250_rx_dma_flush()`: pause/status/copy/terminate or recovery |
| RX worker | `serial8250_rx_dma_flush_work()`: stop/drain, retain ownership on error, restore PIO on success |
| OMAP `FinalFlush`, `ReleaseGate` | Final custom RX flush versus publication of `shutting_down` |

Port-locked consumer operations are atomic model steps. Provider events and
the worker's wait occur separately. The model does not assume an old callback
can be identified from its argument: the real callback receives the reused
port, not a transfer generation. Descriptor IDs exist for the environment and
invariants only.

## Assumptions made explicit

- FIFO counters reset only at flush, not whenever the FIFO becomes empty.
  Writes may wrap and use either end of the mapped buffer. Transfer storage is
  checked against actual overlapping byte positions, not a buffer epoch.
- The provider executes submitted descriptors in order. `active` includes an
  issued descriptor which still owns its storage but is waiting for an older
  descriptor. A descriptor's entire span remains protected until hardware
  completion/stop; partial hardware consumption and cacheline effects are not
  modeled.
- A provider can detach a callback into a tasklet-local list or variable before
  it attempts the UART lock. Cancellation can remove queued callbacks but not
  recall that detached invocation. No spinlock fairness/overtaking assumption
  is needed for the counterexamples.
- `DrainCallbacks` means the **effective DMAengine guarantee**, including stopped
  hardware and returned callbacks. A missing `device_synchronize` pointer alone
  does not establish a violation: termination could already supply the guarantee.
  The unfixed sun6i, classic DW, PL330 and MediaTek UART implementations were
  checked for the detached-callback window as well.
- `CheckStatus` is a hypothetical additional guard, not part of draft v8.
  Classic DW's unfixed `dwc_tx_status()` can scan completed descriptors and invoke
  a callback inline. A status guard under the UART lock can therefore recurse
  into that lock. The separate DW provider series changes this behavior.
- Close does not erase callbacks by definition. `NoUsersAtFree` requires all
  hardware accesses and callback invocations to have retired before free.
  Ignoring a failed `terminate_sync()` in `serial8250_release_dma()` is modeled
  separately from successful termination. That existing error-path limitation
  is not fixed by the v8 callback guard or by a synchronization hook alone.
  This failure is injected by the configuration; this audit has not established
  a reachable termination failure on a particular affected UART/provider pair.
- The TX positive configurations assume successful teardown termination.
  Flush termination failure is independently tested: storage remains reserved
  until normal completion. Progress assumes healthy DMA and eventual scheduling
  of enabled provider/worker actions; it does not assume a failed controller
  eventually recovers.
- RX physical completion does not automatically make the software cookie or
  residue current. `IdlePauseFails` is an environment hypothesis. The consumer
  branches only on pause return/status, never on an invisible `hw_done` flag.
- The RX positive residue case assumes a successful pause stabilizes the buffer
  and that the reported residue describes it accurately. It allows a provider
  to report IN_PROGRESS after a successful pause. Recovery failure keeps RX
  masked and the buffer owned; this is a safe stopping point, not forward
  progress to working PIO.

## Checked configurations

Results from the 2026-10-28 run; counts are generated / distinct states. Passing
negative tests means the expected counterexample was found, **not** that the
condition is fixed.

| Configuration | Result | States |
|---|---|---:|
| `Tx_Drained` | Safety plus reservation/shutdown progress pass | 10,287 / 4,652 |
| `Tx_Drained_WrapRepeated` | Same checks, four buffer slots and two flushes | 119,716 / 54,501 |
| `Tx_NoDrain` | Counterexample: `NoBufferAliasing` | 347 / 234 |
| `Tx_StatusReentry` | Counterexample: `NoCallbackReentry` | 347 / 231 |
| `Tx_StatusNoDrainClose` | Counterexample: `NoUsersAtFree` | 352 / 242 |
| `Tx_FlushFailure` | Failed flush retains storage; normal completion releases it | 2,598 / 1,213 |
| `Tx_CloseFailure` | Counterexample: `NoUsersAtFree` on ignored termination failure | 106 / 71 |
| `Rx_PausedResidue` | Stable, accurately reported RX data and ownership checks pass | 37 / 30 |
| `Rx_IdleBeforeCookie` | Conditional counterexample: `NoCompletedRxDataLost` | 17 / 16 |
| `Rx_RecoveryFailure` | Ownership and masking retained on recovery failure | 84 / 46 |
| `Omap_EarlyGate` | No restart admitted after the final flush | 8 / 6 |
| `Omap_LateGate` | Counterexample: `NoRestartAfterFinalFlush` | 4 / 4 |

TX bounds are three descriptors, three writes including initialization, two
buffer slots and one flush, except `WrapRepeated` uses four slots/two flushes.
RX represents one finite two-byte receive transaction. OMAP is deliberately a
small admission-order model; it does not model the custom RX algorithm.

`CHECK_DEADLOCK FALSE` permits legitimate quiescent terminal states. It is not a
deadlock proof. TX explicitly checks temporal reservation and shutdown progress
under weak fairness. RX checks completion of pending work or entry into the
documented safe failure state. `NoCallbackReentry` tests the specified inline
callback cycle, not every possible kernel lock dependency.

## What the results do and do not justify

1. Restore the running guard, but require real provider callback draining before
   reusing/freeing DMA resources. The guard alone still fails the overlap test.
2. Do not add the review's TX status guard indiscriminately: the classic DW
   status-query side effect must be fixed first, and the guard still does not
   supply teardown synchronization.
3. Set OMAP's shutdown gate under the port lock before its final flush. The new
   OMAP model checks this ordering; C review/builds cover lock ordering and IRQ
   draining separately.
4. Keep the generic RX completion-before-cookie case open. DW AXI's delayed
   cookie/full-residue reporting is visible in source, but the idle-pause
   behavior and a reachable affected UART/platform still need confirmation.
   Tegra210 ADMA is cyclic-only and cannot provide this generic finite transfer;
   TI OMAP UART uses a separate RX path. They are not interchangeable witnesses.
5. Do not copy RX data merely because pause failed, or add a model branch using
   physical completion as if the generic driver could read it. A provider/API
   guarantee or a justified recovery design is needed for a real fix.

The models omit register-level behavior, DMA coherency/cacheline ownership,
partial TX progress, TTY line-discipline behavior, allocation/mapping failures,
runtime PM/suspend/reopen, x_char and most custom OMAP RX logic. The RX model
does not yet cover failed termination after an already copied partial buffer,
DMA_ERROR status, overrun interrupt changes, or repeated buffer generations.
These remain source/runtime review obligations. No hardware test was performed
for this model revision.
