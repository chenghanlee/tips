-- Lint config for the Neovim 0.12.5 runtime Lua in this directory.
std = 'luajit'
read_globals = {
  vim = {
    other_fields = true,
    fields = {
      -- Settings are written through vim.opt.<name> = value.
      opt = { read_only = false, other_fields = true },
      -- neovim_patch_boundaries.lua swaps these for fault injection and restores them.
      api = { other_fields = true, fields = { nvim_buf_call = { read_only = false } } },
      lsp = { other_fields = true, fields = { get_clients = { read_only = false } } },
    },
  },
}
