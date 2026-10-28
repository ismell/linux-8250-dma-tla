#!/usr/bin/env bash
# Keep traces and logs in an isolated directory; never clean the checkout.
set -euo pipefail
model_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
jar=${TLA2TOOLS_JAR:-${model_dir}/tla2tools.jar}
jar=$(realpath -- "$jar")
expected_sha=fc6878c603f0fdc18b9fe3e5bf51860cb90ab5b1154e3c371660c036d6bdd63e
actual_sha=$(sha256sum -- "$jar")
[[ ${actual_sha%% *} == "$expected_sha" ]] || {
    echo 'Unexpected TLC jar; use the pinned v1.8.0 build documented in MODEL-NOTES.md.' >&2
    exit 1
}
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/8250-lifetime.XXXXXXXX")
echo "Retained results: $run_dir"
cp -- "$model_dir"/Serial8250*Lifetime.tla "$model_dir"/Tx_*.cfg \
    "$model_dir"/Rx_*.cfg "$model_dir"/Omap_*.cfg "$run_dir/"
cd -- "$run_dir"
sha256sum -- *.tla *.cfg > inputs.sha256

run_case() {
    local module=$1 config=$2 invariant=${3:-} rc=0
    java -Xmx2g -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
        -workers 1 -seed 1 -fp 0 -metadir "$run_dir/meta-$config" \
        -config "$config.cfg" "$module.tla" > "$config.log" 2>&1 || rc=$?
    if [[ -z $invariant ]]; then
        [[ $rc == 0 ]] && grep -q 'Model checking completed. No error has been found.' "$config.log" || {
            echo "$config: unexpected failure (exit $rc); see $run_dir/$config.log" >&2
            return 1
        }
        echo "$config: PASS"
    else
        [[ $rc == 12 ]] && grep -q "Invariant $invariant is violated\." "$config.log" || {
            echo "$config: expected $invariant, got exit $rc; see $run_dir/$config.log" >&2
            return 1
        }
        echo "$config: expected counterexample ($invariant)"
    fi
    grep 'states generated, .* distinct states found' "$config.log" | tail -n 1
}

run_case Serial8250TxLifetime Tx_Drained
run_case Serial8250TxLifetime Tx_Drained_WrapRepeated
run_case Serial8250TxLifetime Tx_NoDrain NoBufferAliasing
run_case Serial8250TxLifetime Tx_StatusReentry NoCallbackReentry
run_case Serial8250TxLifetime Tx_StatusNoDrainClose NoUsersAtFree
run_case Serial8250TxLifetime Tx_FlushFailure
run_case Serial8250TxLifetime Tx_CloseFailure NoUsersAtFree
run_case Serial8250RxLifetime Rx_PausedResidue
run_case Serial8250RxLifetime Rx_IdleBeforeCookie NoCompletedRxDataLost
run_case Serial8250RxLifetime Rx_RecoveryFailure
run_case Serial8250OmapLifetime Omap_EarlyGate
run_case Serial8250OmapLifetime Omap_LateGate NoRestartAfterFinalFlush
