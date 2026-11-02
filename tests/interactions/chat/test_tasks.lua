local h = require("tests.helpers")
local T = MiniTest.new_set()
local child = MiniTest.new_child_neovim()

T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
    end,
    pre_case = function()
      child.lua([[
        function make_tasks(details)
          local chat = {
            bufnr = vim.api.nvim_create_buf(false, true),
            adapter = { formatted_name = "Agent" },
            acp_connection = { task_detail_supported = function(_, detail) return details and details[detail] end },
            ui = { is_visible = function() return true end },
          }
          chat.tasks = require("codecompanion.interactions.chat.tasks").new(chat)
          chat.tasks:attach("one")
          return chat.tasks, chat
        end
      ]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})

T["Tasks"] = MiniTest.new_set()

T["Tasks"]["tracks shells, progress and terminal states but excludes autonomous turns"] = function()
  local result = child.lua([[
    local tasks = make_tasks({ monitors = true })
    tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "turn", taskType = "turn" })
    tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "shell", taskType = "shell", name = "npm test", canStop = true })
    tasks:update({ sessionUpdate = "async_task_progress", asyncTaskId = "shell", description = "Building" })
    local before = { #tasks.order, tasks.items.shell.description, tasks.items.shell.state }
    tasks:update({ sessionUpdate = "async_task_state_update", asyncTaskId = "shell", state = "failed", summary = "Exit 1" })
    return { before, tasks.items.shell.state, tasks.items.shell.summary, tasks.items.turn }
  ]])
  h.eq({ { 1, "Building", "running" }, "failed", "Exit 1" }, result)
end

T["Tasks"]["clears state on session change and keeps monitors only until sent prompt"] = function()
  local result = child.lua([[
    local tasks = make_tasks({ monitors = true })
    tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "monitor", taskType = "monitor", name = "CI" })
    tasks:update({ sessionUpdate = "async_task_state_update", asyncTaskId = "monitor", state = "completed" })
    local before = #tasks.order
    tasks:clear_finished()
    local after_prompt = #tasks.order
    tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "new", taskType = "shell" })
    tasks:attach("two")
    return { before, after_prompt, #tasks.order, tasks.session_id }
  ]])
  h.eq({ 1, 0, 0, "two" }, result)
end

T["Tasks"]["accepts complete schedule lists only when negotiated"] = function()
  local result = child.lua([[
    local unsupported = make_tasks()
    unsupported:update({ sessionUpdate = "session_schedules_update", schedules = { { id = "a" } } })
    local supported = make_tasks({ schedules = true })
    supported:update({ sessionUpdate = "session_schedules_update", schedules = { { id = "a", prompt = "Check CI" } } })
    supported:update({ sessionUpdate = "session_schedules_update", schedules = { { id = "b", prompt = "Check tests" } } })
    return { #unsupported.schedules, #supported.schedules, supported.schedules[1].id }
  ]])
  h.eq({ 0, 1, "b" }, result)
end

T["Tasks"]["notifies once when a hidden chat's task finishes"] = function()
  local result = child.lua([[
    local tasks, chat = make_tasks()
    chat.ui.is_visible = function() return false end
    local messages = {}
    local notify = vim.notify
    vim.notify = function(message) table.insert(messages, message) end
    tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "shell", taskType = "shell", name = "npm test" })
    tasks:update({ sessionUpdate = "async_task_state_update", asyncTaskId = "shell", state = "failed", summary = "Exit 1" })
    tasks:update({ sessionUpdate = "async_task_state_update", asyncTaskId = "shell", state = "failed" })
    vim.notify = notify
    return messages
  ]])
  h.eq({ "Exit 1" }, result)
end

T["Tasks"]["renders task, schedule, then queue and shows active counts"] = function()
  local result = child.lua([[
    local tasks, chat = make_tasks({ schedules = true })
    local queue = { chat = chat, items = { { text = "next", kind = "pending", state = "pending" } } }
    chat.queue = queue
    tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "shell", taskType = "shell", name = "npm test" })
    tasks:update({ sessionUpdate = "session_schedules_update", schedules = { { id = "a", schedule = "*/20 * * * *", prompt = "Check CI" } } })
    require("codecompanion.interactions.chat.queue.view").render(queue)
    local marks = vim.api.nvim_buf_get_extmarks(chat.bufnr, -1, 0, -1, { details = true })
    local lines = marks[1][4].virt_lines
    return { lines[1][1][1], lines[2][1][1], lines[3][1][1], tasks:counts() }
  ]])
  h.eq("shell · npm test · running", result[1])
  h.eq("every 20 min · Check CI", result[2])
  h.is_true(result[3]:find("Queued 1", 1, true) ~= nil)
  h.eq(1, result[4])
  h.eq(1, result[5])
end

T["Tasks"]["reads the announced RPC output and falls back to a file tail"] = function()
  local result = child.lua([[
    local output = require("codecompanion.interactions.chat.tasks.output")
    local tasks, chat = make_tasks({ output = true })
    chat.acp_connection.session_id = "one"
    function chat.acp_connection:send_rpc_request(method, params)
      self.method, self.params = method, params
      return { output = "rpc output" }
    end
    local rpc
    output.read({ chat = chat, task = { asyncTaskId = "shell" }, callback = function(value) rpc = value end })
    vim.wait(100, function() return rpc ~= nil end)
    chat.acp_connection.task_detail_supported = function() return false end
    local path = vim.fn.tempname()
    vim.fn.writefile({ string.rep("a", 8192), "file tail" }, path)
    local file
    output.read({ chat = chat, task = { outputFilePath = path }, callback = function(value) file = value end })
    vim.fn.delete(path)
    local missing
    output.read({ chat = chat, task = {}, callback = function(value) missing = value or "missing" end })
    return { rpc, chat.acp_connection.method, chat.acp_connection.params.asyncTaskId, #file, file:sub(-9), missing }
  ]])
  h.eq({ "rpc output", "_session/async_task/output", "shell", 8192, "ile tail\n", "missing" }, result)
end

T["Tasks"]["opens output above the chat without changing the window layout"] = function()
  local result = child.lua([[
    local tasks, chat = make_tasks()
    chat.ui.winnr = vim.api.nvim_get_current_win()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    require("codecompanion.interactions.chat.tasks.output").open({ chat = chat, task = { name = "npm test", state = "completed" } })
    local win = vim.api.nvim_get_current_win()
    local window_config = vim.api.nvim_win_get_config(win)
    return { before, #vim.api.nvim_tabpage_list_wins(0), window_config.relative, window_config.title }
  ]])
  h.eq(result[1], result[2] - 1)
  h.eq("win", result[3])
  h.eq("npm test", result[4][1][1])
end

T["Tasks"]["stops a selected task and asks the agent to cancel a selected schedule"] = function()
  local result = child.lua([[
    local tasks, chat = make_tasks({ schedules = true })
    local sent = {}
    chat.queue = { chat = chat, items = {} }
    function chat.queue:add(item) table.insert(sent, item.text) end
    function chat.acp_connection:send_rpc_request(method, params)
      self.method, self.params = method, params
      return { stopped = true }
    end
    tasks:update({ sessionUpdate = "async_task_spawned", asyncTaskId = "shell", taskType = "shell", name = "test", canStop = true })
    tasks:update({ sessionUpdate = "session_schedules_update", schedules = { { id = "schedule-1", schedule = "*/20 * * * *", prompt = "Check CI" } } })
    local view = require("codecompanion.interactions.chat.queue.view")
    view.open(chat.queue)
    local bufnr = vim.api.nvim_get_current_buf()
    local function press(key)
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if mapping.lhs == key then mapping.callback(); return end
      end
    end
    vim.ui.select = function(_, _, callback) callback("Stop") end
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    press("s")
    vim.wait(100, function() return tasks.items.shell.state == "stopped" end)
    local state = tasks.items.shell.state
    local method = chat.acp_connection.method
    local id = chat.acp_connection.params.asyncTaskId
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    press("x")
    return { state, method, id, sent[1] }
  ]])
  h.eq({ "stopped", "_session/async_task/stop", "shell", "Cancel scheduled task schedule-1" }, result)
end

return T
