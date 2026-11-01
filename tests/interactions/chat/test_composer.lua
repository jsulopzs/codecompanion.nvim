local h = require("tests.helpers")
local T = MiniTest.new_set()
local child = MiniTest.new_child_neovim()

T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[h = require("tests.helpers")]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})

T["Composer"] = MiniTest.new_set()

T["Composer"]["is editable while the history is locked"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    chat.current_request = {}
    local ok = pcall(vim.api.nvim_buf_set_lines, chat.composer.bufnr, 0, -1, false, { "Next prompt" })
    return { writable = ok, history_locked = not vim.bo[chat.bufnr].modifiable, draft = vim.api.nvim_buf_get_lines(chat.composer.bufnr, 0, -1, false)[1] }
  ]])
  h.is_true(result.writable)
  h.is_true(result.history_locked)
  h.eq("Next prompt", result.draft)
end

T["Composer"]["submits text as a visible user message"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    function chat:_submit_acp(payload)
      self.sent_payload = payload
      self.current_request = {}
    end
    local accepted = chat:send_text("First line\nSecond line")
    local buffer = table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), "\n")
    return { accepted = accepted, message = chat.messages[#chat.messages].content, visible = buffer:find("First line", 1, true) ~= nil }
  ]])
  h.is_true(result.accepted)
  h.eq("First line\nSecond line", result.message)
  h.is_true(result.visible)
end

return T
