# test-runner.nvim

> [!WARNING] This plugin is in very early stages. Features described in the documentation might not yet exist.

`test-runner.nvim` runs tests inside of neovim, and parses the output into
`vim.diagnostic` entries, so you can see failures alongside compilation errors.

This plugin is not intended to do anything more than showing test failure
diagnostics inside neovim, and only supports test runners that I've needed this
feature for. For a more capable and well-maintained test runner plugin, see
    [neotest](https://github.com/nvim-neotest/neotest).

Supported test runners:
- [Zig](/docs/adapters/zig.md)

## Installation

```lua
vim.pack.add({
  "https://github.com/rasmus105/test-runner.nvim",
})

require("test-runner").setup()

-- setup whatever keymaps you need, for example:
vim.keymap.set("n", "<leader>tc", ":TestRunnerRunAtCursor<CR>");
vim.keymap.set("n", "<leader>tf", ":TestRunnerRunFile<CR>");
vim.keymap.set("n", "<leader>ta", ":TestRunnerRunAll<CR>");
vim.keymap.set("n", "<leader>tt", ":TestRunnerRunAll<CR>");
-- ...
```

## Commands

| Command | Description |
| --- | --- |
| `:TestRunnerDiscover` | Discover tests. |
| `:TestRunnerRunAtCursor` | Run the test nearest to the cursor. |
| `:TestRunnerRunFile` | Run all tests in the current file. |
| `:TestRunnerRunAll` | Run all tests within the project. |
| `:TestRunnerRunLast` | Re-run the most recent test command. |
| `:TestRunnerClear` | Clear test diagnostics and decorations. |
| `:TestRunnerEnable` | Enable test discovery, commands, diagnostics, and decorations. |
| `:TestRunnerDisable` | Disable test discovery, commands, diagnostics, and decorations. |
| `:TestRunnerToggle` | Toggle the plugin between enabled and disabled. |

## Configuration

These are the defaults:

```lua
require("test-runner").setup({
  -- Set to false to disable discovery, commands, diagnostics, and decorations.
  enabled = true,
  adapters = {
    fake = {
      enabled = false,
    },
    zig = {
      enabled = true,

      -- Zig build step passed to the bundled build runner.
      step = "test",

      -- Extra args appended after the step.
      build_args = {},
    },
  },
  discovery = {
    -- Discover tests automatically when opening or writing buffers.
    auto = true,
    events = { "BufEnter", "BufWritePost" },
  },
  ui = {
    inline = {
      -- Show inline status icons next to discovered tests.
      enabled = true,
      click = false,
      virt_text_pos = "eol",
      icons = {
        idle = "",
        running = "",
        passed = "",
        failed = "",
        blocked = "",
      },
    },
  },
})
```


## Links

- [zls](https://github.com/zigtools/zls)
- [zig custom test runner example](https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b)
- [zig build runner](https://codeberg.org/ziglang/zig/src/branch/master/lib/compiler/build_runner.zig)
