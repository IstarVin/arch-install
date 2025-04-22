return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    window = {
      position = "right",
      mappings = {
        ["<C-\\>"] = {
          function(state)
            local node = state.tree:get_node()
            local path = node:get_id()
            vim.api.nvim_command("botright vsplit " .. path)
          end,
        },
        ["<C-S-->"] = {
          function(state)
            local node = state.tree:get_node()
            local path = node:get_id()
            vim.api.nvim_command("split " .. path)
          end,
        },
      },
    },
  },
}
