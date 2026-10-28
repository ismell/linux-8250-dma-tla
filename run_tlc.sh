#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TLA2TOOLS_VERSION="v1.8.0"
TLA2TOOLS_URL="https://github.com/tlaplus/tlaplus/releases/download/${TLA2TOOLS_VERSION}/tla2tools.jar"
JAR_PATH="${SCRIPT_DIR}/tla2tools.jar"

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
    local expected_invariant="${4:-}"

    local meta_dir="${TMP_DIR}/meta_${config%.cfg}"
    local out_file="${TMP_DIR}/${config%.cfg}.out"

    echo "========================================================================"
    echo "Model:  ${module}"
    echo "Config: ${config} (Expected: ${expected_result}${expected_invariant:+ - ${expected_invariant}})"
    echo "========================================================================"

    set +e
    java -XX:+UseParallelGC -cp "${JAR_PATH}" tlc2.TLC \
        -workers 1 \
        -cleanup \
        -metadir "${meta_dir}" \
        -config "${config}" \
        "${module}" > "${out_file}" 2>&1
    local rc=$?
    set -e

    rm -f "${SCRIPT_DIR}"/*_TTrace_*

    local summary_line
    summary_line="$(grep -E 'states generated, .* distinct states found' "${out_file}" | tail -n 1 || true)"

    if [[ "${expected_result}" == "PASS" ]]; then
        if [[ ${rc} -ne 0 ]] || ! grep -q "Model checking completed. No error has been found." "${out_file}"; then
            echo "ERROR: Expected ${config} to PASS, but TLC exited with rc=${rc}:"
            cat "${out_file}"
            exit 1
        fi
        echo "Result: PASS (0 errors) -- ${summary_line}"
    else
        if [[ ${rc} -eq 0 ]]; then
            echo "ERROR: Expected ${config} to FAIL (${expected_invariant}), but TLC succeeded!"
            cat "${out_file}"
            exit 1
        fi
        if ! grep -q "Invariant ${expected_invariant} is violated." "${out_file}"; then
            echo "ERROR: Expected ${config} to violate ${expected_invariant}, but got:"
            cat "${out_file}"
            exit 1
        fi
        echo "Result: EXPECTED FAIL (Invariant ${expected_invariant} violated) -- ${summary_line}"
        echo ""
        sed -n '/^Error: Invariant /,/^Finished in /p' "${out_file}"
    fi
    echo ""
}

# 1. TX DMA Formal Model (Patch 1/5, Patch 2/5, Patch 3/5, Patch 4/5)
run_case "Serial8250TxDmaV7.tla" "Serial8250TxDmaV7_Ideal.cfg"                        "PASS"
run_case "Serial8250TxDmaV7.tla" "Serial8250TxDmaV7_NoSync.cfg"                       "FAIL" "NoStaleCallbackCorruption"
run_case "Serial8250TxDmaV7.tla" "Serial8250TxDmaV7_NoSync_Fixed.cfg"                 "PASS"
run_case "Serial8250TxDmaV7.tla" "Serial8250TxDmaV7_NoSync_BufferAliasing.cfg"        "FAIL" "NoBufferAliasing"
run_case "Serial8250TxDmaV7.tla" "Serial8250TxDmaV7_NoSync_BufferAliasing_Fixed.cfg"  "PASS"

# 2. RX DMA Formal Model (Patch 5/5)
run_case "Serial8250RxDmaV7.tla" "Serial8250RxDmaV7_Ideal.cfg"                        "PASS"
run_case "Serial8250RxDmaV7.tla" "Serial8250RxDmaV7_HwDoneBeforeIrq.cfg"              "FAIL" "NoCompletedRxDataLost"
run_case "Serial8250RxDmaV7.tla" "Serial8250RxDmaV7_HwDoneBeforeIrq_Fixed.cfg"        "PASS"

echo "All 8 TLA+ model checking configurations matched expected results."
