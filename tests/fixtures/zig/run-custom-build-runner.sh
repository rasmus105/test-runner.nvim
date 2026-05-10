SCRIPT_DIR="$(realpath "$(dirname "$0")")"

export TRNVIM_EVENT_DIR="$SCRIPT_DIR/.trnvim-events"
export TRNVIM_TEST_RUNNER="$SCRIPT_DIR/../../../lua/test-runner/adapters/zig/test_runner.zig"

mkdir -p "$TRNVIM_EVENT_DIR"
rm -f "$TRNVIM_EVENT_DIR"/*.jsonl "$TRNVIM_EVENT_DIR"/stderr-*.txt

zig build --build-runner \
        "$SCRIPT_DIR/../../../lua/test-runner/adapters/zig/build_runner.zig" \
        test
