#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TLA2TOOLS_VERSION="v1.8.0"
TLA2TOOLS_URL="https://github.com/tlaplus/tlaplus/releases/download/${TLA2TOOLS_VERSION}/tla2tools.jar"
JAR_PATH="${TLA2TOOLS_JAR:-${SCRIPT_DIR}/tla2tools.jar}"

if [[ ! -f "${JAR_PATH}" ]]; then
    echo "Downloading tla2tools.jar (${TLA2TOOLS_VERSION})..."
    curl -fsSL -o "${JAR_PATH}" "${TLA2TOOLS_URL}"
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}" "${SCRIPT_DIR}"/*_TTrace_*
}
trap cleanup EXIT

run_case() {
    local module="$1"
    local config="$2"
    local expected_result="$3"
    local expected_violation="${4:-}"

    local meta_dir="${TMP_DIR}/meta_${config%.cfg}"
    local out_file="${TMP_DIR}/${config%.cfg}.out"

    echo "========================================================================"
    echo "Model:  ${module}"
    echo "Config: ${config} (Expected: ${expected_result}${expected_violation:+ - ${expected_violation}})"
    echo "========================================================================"

    set +e
    java -XX:+UseParallelGC -cp "${JAR_PATH}" tlc2.TLC \
        -workers 1 \
        -cleanup \
        -coverage 1 \
        -metadir "${meta_dir}" \
        -config "${config}" \
        "${module}" > "${out_file}" 2>&1
    local rc=$?
    set -e

    rm -f "${SCRIPT_DIR}"/*_TTrace_*

    local summary_line
    summary_line="$(grep -E 'states generated, .* distinct states found' "${out_file}" | tail -n 1 || true)"
    local depth_line
    depth_line="$(grep -E '^The depth of the complete state graph search is' "${out_file}" | tail -n 1 || true)"

    if [[ "${expected_result}" == "PASS" ]]; then
        if [[ ${rc} -ne 0 ]] || ! grep -q "Model checking completed. No error has been found." "${out_file}"; then
            echo "ERROR: Expected ${config} to PASS, but TLC exited with rc=${rc}:"
            cat "${out_file}"
            exit 1
        fi
        echo "Result: PASS (0 errors) -- ${summary_line} (${depth_line})"
    else
        if [[ ${rc} -eq 0 ]]; then
            echo "ERROR: Expected ${config} to FAIL (${expected_violation}), but TLC succeeded!"
            cat "${out_file}"
            exit 1
        fi
        if ! grep -Eq "Invariant ${expected_violation} is violated\.|Temporal property ${expected_violation} was violated\." "${out_file}"; then
            echo "ERROR: Expected ${config} to violate ${expected_violation}, but got:"
            cat "${out_file}"
            exit 1
        fi
        echo "Result: EXPECTED FAIL (${expected_violation} violated) -- ${summary_line} (${depth_line})"
        echo ""
        sed -n '/^Error: /,/^The coverage statistics/p' "${out_file}" | sed '$d'
    fi
    echo ""
}

# 1. RX DMA v8 Formal Model (Patch 5/6: 2f1127ac7473)
run_case "Serial8250RxDmaV8.tla" "Serial8250RxDmaV8_Ideal.cfg"                                "PASS"
run_case "Serial8250RxDmaV8.tla" "Serial8250RxDmaV8_HwDoneBeforeIrq.cfg"                      "PASS"
run_case "Serial8250RxDmaV8.tla" "Serial8250RxDmaV8_RecoverFallback.cfg"                      "PASS"
run_case "Serial8250RxDmaV8.tla" "Serial8250RxDmaV8_PartialTransferPauseFails.cfg"            "FAIL" "WorkerBoundedRetries"
run_case "Serial8250RxDmaV8.tla" "Serial8250RxDmaV8_PartialTransferPauseFails_Fixed.cfg"      "PASS"
run_case "Serial8250RxDmaV8.tla" "Serial8250RxDmaV8_DwIdleEnterDuringPausePending.cfg"        "FAIL" "NoAbortedDivisorProgramming"

# 2. TX DMA & Serial Core v8 Formal Model (Patch 3/6: dc41a4f7ebbd, Patch 4/6: 5eb9d13feb8c, Patch 6/6: 118587b34be5)
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_Ideal.cfg"                                "PASS"
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_NoSync_ActiveTransferAliasing.cfg"        "FAIL" "NoBufferAliasing"
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_NoSync_Fixed.cfg"                         "PASS"
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_LostFlushWakeup.cfg"                      "FAIL" "NoLostFlushWaiterWakeup"
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_LostFlushWakeup_Fixed.cfg"                "PASS"
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_TerminateRetryHang.cfg"                   "FAIL" "BoundedTerminateRetries"
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_QuarantinePioReopenHazard.cfg"            "FAIL" "NoConcurrentFifoAccess"
run_case "Serial8250TxDmaV8.tla" "Serial8250TxDmaV8_TerminateRetryHang_Fixed.cfg"             "PASS"

echo "All 14 v8 TLA+ model checking configurations matched expected results."
