## v0.1.0 - Initial Rough Outline

- [x] Vim diagnostics support.
- [x] Simple interface for adding new adapter for test runners.
- [x] Commands for running all tests, tests within the current file, and a
  single test case.
- [x] Inline clickable run icon, changing depending on status (running,
  success, failure, compilation error)

## v0.2.0 - Robust Zig Adapter

- [x] Replace the zig lua stdout/stderr output parsing from `zig build test
  -Dtest-filter=<test name>` with a custom zig build runner that patches the
  `zig build test` step with a custom test runner, and test filter.
- [x] Update zig lua adapter to work with the custom zig build runner.
- [x] Use treesitter for zig test discovery instead of regex searching (which
      could more easily fail)
- [x] Verify test runner works across different projects.

**Edge Cases:**
- Might compile and run test multiple times with different comptime configurations. Therefore we must de-duplicate errors.

## v0.3.0 - QOL

- [ ] Add hints for better tracing of issues (zig).
- [ ] Think about anonymous tests and how to handle those (zig)

## vX.Y.Z

**Add runners:**
- Rust
- Jest
- Bun
    
