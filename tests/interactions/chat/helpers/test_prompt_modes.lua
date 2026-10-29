local h = require("tests.helpers")

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        chat = h.setup_chat_buffer()
        vim.api.nvim_set_current_buf(chat.bufnr)

        -- Pretend the user is typing, and record whether the prompt leaves insert mode
        _G.left_insert = false
        local get_mode = vim.api.nvim_get_mode
        vim.api.nvim_get_mode = function() return { mode = "i", blocking = false } end
        local cmd = vim.cmd
        vim.cmd = setmetatable({}, {
          __call = function(_, c) if c == "stopinsert" then _G.left_insert = true else return cmd(c) end end,
          __index = cmd,
        })

        function approve()
          require("codecompanion.interactions.chat.helpers.approval_prompt").request(chat, {
            id = 1,
            title = "Run a command",
            choices = { { keymap = "g2", label = "Accept", callback = function() end } },
          })
        end
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["prompts"] = new_set()

T["prompts"]["an approval takes the chat out of insert mode so its keys answer"] = function()
  child.lua([[approve()]])
  h.eq(true, child.lua_get("_G.left_insert"))
end

T["prompts"]["a question takes the chat out of insert mode so its keys answer"] = function()
  child.lua([[
    require("codecompanion.interactions.chat.helpers.question_prompt").ask(chat, {
      question = { question = "Colour?", options = { { label = "Red" }, { label = "Blue" } } },
      index = 1,
      total = 1,
      callback = function() end,
    })
  ]])
  h.eq(true, child.lua_get("_G.left_insert"))
end

T["prompts"]["typing in another buffer is left alone"] = function()
  child.lua([[
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
    approve()
  ]])
  h.eq(false, child.lua_get("_G.left_insert"))
end

return T
