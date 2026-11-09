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

T["restore_session"]["does not assign the current model to replies restored without model information"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Agent" } })
    local connection = require("codecompanion.acp").new({ adapter = chat.adapter, chat = chat, session_id = "restored" })
    chat.acp_connection = connection
    connection:_apply_config_options({
      { id = "model", category = "model", type = "select", currentValue = "current-model", options = {} },
      { id = "effort", category = "thought_level", type = "select", currentValue = "high", options = {} },
    })
    require("codecompanion.interactions.chat.acp.render").restore_session(chat, {
      { sessionUpdate = "user_message_chunk", content = { type = "text", text = "Earlier question" } },
      { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Earlier reply" } },
    })
    return { table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), "\n"), require("codecompanion.interactions.chat.model_info").snapshot(chat) }
  ]])
  h.expect_contains("unknown · effort unknown", result[1])
  h.is_false(result[1]:find("current-model", 1, true) ~= nil)
  h.eq("current-model", result[2].model)
  h.eq("high", result[2].effort)
end

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
    return { last_header = last_header, user_header = "## " .. (type(user) == "function" and user() or user), history_modifiable = vim.bo[chat.bufnr].modifiable, composer_modifiable = vim.bo[chat.composer.bufnr].modifiable }
  ]])

  h.eq(result.user_header, result.last_header)
  h.eq(false, result.history_modifiable)
  h.eq(true, result.composer_modifiable)
end

return T
