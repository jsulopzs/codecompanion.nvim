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

T["Composer"]["stays below its chat after horizontal and vertical splits close"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    local api = vim.api
    local composer = chat.composer
    api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { "Unsent draft" })
    local function attached()
      local chat_position = api.nvim_win_get_position(chat.ui.winnr)
      local composer_position = api.nvim_win_get_position(composer.winnr)
      return chat_position[2] == composer_position[2]
        and api.nvim_win_get_width(chat.ui.winnr) == api.nvim_win_get_width(composer.winnr)
        and composer_position[1] == chat_position[1] + api.nvim_win_get_height(chat.ui.winnr) + 1
    end
    api.nvim_set_current_win(chat.ui.winnr)
    vim.cmd("belowright split")
    vim.wait(100, attached)
    local horizontal = attached()
    vim.cmd("vsplit")
    vim.wait(100, attached)
    local vertical = attached()
    api.nvim_win_close(api.nvim_get_current_win(), true)
    vim.wait(100, attached)
    return { horizontal, vertical, attached(), api.nvim_buf_get_lines(composer.bufnr, 0, -1, false)[1] }
  ]])
  h.eq({ true, true, true, "Unsent draft" }, result)
end

T["Composer"]["keeps its height when other windows open and close"] = function()
  local result = child.lua([[
    vim.o.lines = 45
    vim.o.columns = 160
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    local api = vim.api
    local composer = chat.composer
    local initial = api.nvim_win_get_height(composer.winnr)
    api.nvim_set_current_win(chat.ui.winnr)
    vim.cmd("belowright split")
    local opened = api.nvim_win_get_height(composer.winnr)
    api.nvim_set_current_win(chat.ui.winnr)
    vim.cmd("vsplit")
    local vertical = api.nvim_win_get_height(composer.winnr)
    api.nvim_win_close(api.nvim_get_current_win(), true)
    api.nvim_win_set_height(composer.winnr, 5)
    api.nvim_exec_autocmds("WinResized", {})
    vim.wait(100, function() return api.nvim_win_get_height(composer.winnr) == initial end)
    return { initial, opened, vertical, api.nvim_win_get_height(composer.winnr) }
  ]])
  h.eq({ 3, 3, 3, 3 }, result)
end

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

T["Composer"]["shows the keys under the text, whatever the statusline"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    local function hint()
      local marks = vim.api.nvim_buf_get_extmarks(chat.composer.bufnr, -1, 0, -1, { details = true })
      local mark = marks[#marks]
      return { row = mark[2], text = mark[4].virt_lines[1][1][1] }
    end
    local idle = hint()
    vim.api.nvim_buf_set_lines(chat.composer.bufnr, 0, -1, false, { "one", "two" })
    chat.current_request = {}
    chat.composer:update_status()
    return { idle = idle, busy = hint() }
  ]])
  h.eq(0, result.idle.row)
  h.expect_contains("<C-s> send", result.idle.text)
  h.expect_contains("<M-CR> queue", result.idle.text)
  h.eq(1, result.busy.row)
  h.expect_contains("<C-s> correct", result.busy.text)
  h.expect_contains("q stop", result.busy.text)
end

T["Composer"]["shows active task and schedule counts only when present"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    local function hint()
      local marks = vim.api.nvim_buf_get_extmarks(chat.composer.bufnr, -1, 0, -1, { details = true })
      return marks[#marks][4].virt_lines[1][1][1]
    end
    local empty = hint()
    chat.acp_connection = { task_detail_supported = function(_, detail) return detail == "schedules" end }
    chat.tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "one", taskType = "shell", name = "build" })
    chat.tasks:update({ sessionUpdate = "session_schedules_update", schedules = { { id = "every-20" } } })
    return { empty, hint() }
  ]])
  h.is_false(result[1]:find("tasks", 1, true) ~= nil)
  h.expect_contains("1 task · 1 scheduled", result[2])
end

T["Composer"]["shows context usage and updates it after a new usage report"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    local connection = require("codecompanion.acp").new({ adapter = chat.adapter, chat = chat, session_id = "usage-session" })
    local function segments()
      local marks = vim.api.nvim_buf_get_extmarks(chat.composer.bufnr, -1, 0, -1, { details = true })
      return marks[#marks][4].virt_lines[1]
    end
    local before = segments()
    local function report(used, size)
      connection:handle_incoming_request_or_notification({ method = "session/update", params = { sessionId = "usage-session", update = { sessionUpdate = "usage_update", used = used, size = size } } })
    end
    report(71407, 1000000)
    local first = segments()
    report(850000, 1000000)
    local warned = segments()
    report(120000, 1000000)
    local after = segments()
    return { before = #before, first = first[2], warned = warned[2], after = after[2], tokens = chat.tokens, used = chat.context_usage.used }
  ]])
  h.eq(1, result.before)
  h.eq({ " · ctx 7% 71k/1M", "Comment" }, result.first)
  h.eq({ " · ctx 85% 850k/1M", "WarningMsg" }, result.warned)
  h.eq({ " · ctx 12% 120k/1M", "Comment" }, result.after)
  h.eq(120000, result.tokens)
  h.eq(120000, result.used)
end

T["Composer"]["shows one history notice for a completed compaction"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({ display = { chat = { stream_interval = 0 } } }, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    local connection = require("codecompanion.acp").new({ adapter = chat.adapter, chat = chat, session_id = "compaction-session" })
    local function report(update)
      connection:handle_incoming_request_or_notification({ method = "session/update", params = { sessionId = "compaction-session", update = update } })
    end
    local function hint()
      local marks = vim.api.nvim_buf_get_extmarks(chat.composer.bufnr, -1, 0, -1, { details = true })
      return marks[#marks][4].virt_lines[1][1][1]
    end
    report({ sessionUpdate = "compaction_update", compactionId = "compact-1", status = "in_progress" })
    local during = hint()
    local completed = { sessionUpdate = "compaction_update", compactionId = "compact-1", status = "completed", _meta = { jetbrains = { air = { contextCompaction = { preTokens = 944000, postTokens = 120000 } } } } }
    report(completed)
    report(completed)
    chat.builder:flush()
    local history = table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), "\n")
    return { during = during, after = hint(), history = history }
  ]])
  h.expect_contains("compacting…", result.during)
  h.is_false(result.after:find("compacting…", 1, true) ~= nil)
  h.eq(1, select(2, result.history:gsub("compacted · 944k → 120k", "")))
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

T["Composer"]["removes a queued prompt when its agent starts streaming"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    chat.acp_connection = {}
    chat.current_request = {}
    chat.queue:add({ text = "next" })
    function chat:send_text() self.current_request = {}; return true end
    chat.current_request = nil
    chat.queue:dispatch()
    local item = chat.queue.sending
    vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanionRequestStreaming", data = { bufnr = chat.bufnr } })
    return { remaining = #chat.queue.items, state = item.state, sending = chat.queue.sending == item }
  ]])
  h.eq(0, result.remaining)
  h.eq("sent", result.state)
  h.is_true(result.sending)
end

T["Composer"]["shows an injected correction as a separate user message"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
    function chat:_submit_acp() self.current_request = {} end
    chat:send_text("Respond with AZUL.")
    chat.acp_connection = {
      session_id = "session-1",
      can_steer = function() return true end,
      steer = function(_, opts) opts.callback(true); return true end,
    }
    chat:send_now("Change to ROJO.")
    local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
    local before, correction
    local headers = 0
    for index, line in ipairs(lines) do
      if line == "## foo" then headers = headers + 1 end
      if line:find("Respond with AZUL.", 1, true) then before = index end
      if line:find("Correction: Change to ROJO.", 1, true) then correction = index end
    end
    return { separate = before ~= correction, correction = correction and lines[correction], marked = chat.messages[#chat.messages]._meta.correction, headers = headers }
  ]])
  h.is_true(result.separate)
  h.eq("Correction: Change to ROJO.", result.correction)
  h.is_true(result.marked)
  h.eq(2, result.headers)
end

return T
