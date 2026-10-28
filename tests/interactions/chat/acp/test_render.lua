local h = require("tests.helpers")

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[h = require('tests.helpers')]])
    end,
    post_once = child.stop,
  },
})

T["restore_session"] = new_set()

T["restore_session"]["ends on a user header the user can type into"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp" } })
    -- Streamed text is queued, as with the default stream_interval
    require("codecompanion.config").display.chat.stream_interval = 25
    -- The chat already ended on a user header, as any chat does between turns
    chat:ready_for_input()

    require("codecompanion.interactions.chat.acp.render").restore_session(chat, {
      { sessionUpdate = "user_message_chunk", content = { type = "text", text = "Hello" } },
      { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Hi there" } },
    })

    -- Let any queued text reach the buffer, as it would a moment later
    vim.wait(500, function() return chat.builder._queue == nil end, 10)
    local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
    local last_header
    for _, line in ipairs(lines) do
      if line:match("^## ") then last_header = line end
    end
    local user = require("codecompanion.config").interactions.chat.roles.user
    return { last_header = last_header, user_header = "## " .. (type(user) == "function" and user() or user), modifiable = vim.bo[chat.bufnr].modifiable }
  ]])

  h.eq(result.user_header, result.last_header)
  h.eq(true, result.modifiable)
end

return T
