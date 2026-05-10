## v0.1.0 - Initial Rough Outline

- [x] Vim diagnostics support.
- [x] Simple interface for adding new adapter for test runners.
- [x] Commands for running all tests, tests within the current file, and a
  single test case.
- [x] Inline clickable run icon, changing depending on status (running,
  success, failure, compilation error)

## v0.2.0 - Robust Zig Adapter

- [ ] Replace the zig lua stdout/stderr output parsing from `zig build test
  -Dtest-filter=<test name>` with a custom zig build runner that patches the
  `zig build test` step with a custom test runner, and test filter.
- [ ] Update zig lua adapter to work with the custom zig build runner.

## vX.Y.Z

- [ ] Use treesitter for zig test discovery instead of regex searching (which
  could more easily fail)

**Add runners:**
- Rust
- Jest
- Bun
    
