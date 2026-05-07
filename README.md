# test-runner.nvim

`test-runner.nvim` runs tests inside of neovim, and parses the output into
`vim.diagnostic` entries, so you can see failures alongside compilation errors.

Currently supported runners:
- Zig

## Installation

```lua
vim.pack.add({
  "https://github.com/rasmus105/test-runner.nvim",
})

require("test-runner").setup()
```

## Commands

- `:TestRunnerDiscover`
- `:TestRunnerRunAtCursor`
- `:TestRunnerRunFile`
- `:TestRunnerRunAll`
- `:TestRunnerRunLast`
- `:TestRunnerClear`
- `:TestRunnerEnable`
- `:TestRunnerDisable`
- `:TestRunnerToggle`

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

      -- Base command used for every Zig test run.
      build = { "zig", "build", "test", "--summary", "all" },

      -- When true, compiler errors are also shown as diagnostics.
      compiler_diagnostics = false,

      -- Called when running one non-project test. Return extra arguments
      -- appended to `build`.
      --
      -- `test` has this shape:
      -- {
      --   id = string,
      --   name = string,
      --   file = string,
      --   root = string,
      --   scope = "nearest" | "file" | "all",
      --   lnum = number,
      --   col = number,
      --   end_lnum = number,
      -- }
      filter = function(test)
        return { "-Dtest-filter=" .. test.name }
      end,
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
