local M = {}
local namespace = vim.api.nvim_create_namespace("codecompanion_chat_queue")

local function schedule_label(schedule)
  local expression = schedule.schedule or ""
  local minutes = expression:match("^%*/(%d+) %* %* %* %*$")
  if minutes then
    return "every " .. minutes .. " min"
  end
  local hours = expression:match("^0 %*/(%d+) %* %* %*$")
  if hours then
    return "every " .. hours .. " hours"
  end
  local hour, minute = expression:match("^(%d+) (%d+) %* %* %*$")
  if hour then
    return string.format("daily at %02d:%02d", tonumber(minute), tonumber(hour))
  end
  return expression
end

---@param queue table
function M.render(queue)
  local bufnr = queue.chat.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local lines = {}
  local tasks = queue.chat.tasks
  if tasks then
    for _, id in ipairs(tasks.order) do
      local task = tasks.items[id]
      table.insert(
        lines,
        { { string.format("%s · %s · %s", task.taskType or "task", task.name or id, task.state), "Comment" } }
      )
    end
    for _, schedule in ipairs(tasks.schedules) do
      table.insert(
        lines,
        { { schedule_label(schedule) .. " · " .. (schedule.prompt or ""):gsub("\n", " "), "Comment" } }
      )
    end
  end
  for index, item in ipairs(queue.items) do
    local label = item.kind == "parked" and "Parked" or (item.state == "failed" and "Failed" or "Queued")
    table.insert(lines, { { string.format("%s %d  %s", label, index, item.text:gsub("\n", " ")), "Comment" } })
  end
  if #lines > 0 then
    vim.api.nvim_buf_set_extmark(bufnr, namespace, vim.api.nvim_buf_line_count(bufnr) - 1, 0, {
      virt_lines = lines,
      virt_lines_above = false,
    })
  end
end

---@param queue table
function M.open(queue)
  local lines = {
    "Queue: <CR> send, e edit, dd delete, K/J move, P first, p park/queue, r resume, " .. require(
      "codecompanion.config"
    ).interactions.chat.composer.keymaps.compact .. " compact",
  }
  local rows = {}
  table.insert(lines, "Queue")
  rows[#lines] = { section = "queue" }
  for index, item in ipairs(queue.items) do
    table.insert(lines, string.format("%d  [%s, %s] %s", index, item.kind, item.state, item.text:gsub("\n", " ")))
    rows[#lines] = { section = "queue", index = index }
  end
  local tasks = queue.chat.tasks
  table.insert(lines, "Tasks")
  rows[#lines] = { section = "tasks" }
  if tasks then
    for index, id in ipairs(tasks.order) do
      local task = tasks.items[id]
      table.insert(
        lines,
        string.format(
          "%d  [%s] %s · %s",
          index,
          task.state,
          task.taskType or "task",
          (task.name or id):gsub("\n", " ")
        )
      )
      rows[#lines] = { section = "tasks", index = index }
    end
  end
  table.insert(lines, "Schedules")
  rows[#lines] = { section = "schedules" }
  if tasks then
    for index, schedule in ipairs(tasks.schedules) do
      table.insert(
        lines,
        string.format("%d  %s · %s", index, schedule_label(schedule), (schedule.prompt or ""):gsub("\n", " ↵ "))
      )
      rows[#lines] = { section = "schedules", index = index }
    end
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local width = math.min(100, math.max(50, vim.o.columns - 8))
  local height = math.min(#lines + 2, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = 2,
    col = math.floor((vim.o.columns - width) / 2),
  })
  local function selected()
    return rows[vim.api.nvim_win_get_cursor(win)[1]]
  end
  local function refresh()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      M.open(queue)
    end
  end
  local function change(opts)
    local row = selected()
    if not row or row.section ~= "queue" then
      return
    end
    opts.index = row.index
    queue:change(opts)
    refresh()
  end
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = bufnr })
  vim.keymap.set("n", "r", function()
    queue:resume()
    refresh()
  end, { buffer = bufnr })
  vim.keymap.set("n", "dd", function()
    change({ remove = true })
  end, { buffer = bufnr })
  vim.keymap.set("n", "K", function()
    change({ offset = -1 })
  end, { buffer = bufnr })
  vim.keymap.set("n", "J", function()
    change({ offset = 1 })
  end, { buffer = bufnr })
  vim.keymap.set("n", "P", function()
    change({ first = true })
  end, { buffer = bufnr })
  vim.keymap.set("n", "p", function()
    local row = selected()
    local item = row and row.section == "queue" and queue.items[row.index]
    if item then
      change({ kind = item.kind == "parked" and "pending" or "parked" })
    end
  end, { buffer = bufnr })
  vim.keymap.set("n", "e", function()
    local row = selected()
    local index = row and row.section == "queue" and row.index
    local item = queue.items[index]
    if item then
      vim.ui.input({ prompt = "Edit queued prompt: ", default = item.text }, function(value)
        if value and value ~= "" then
          queue:change({ index = index, text = value })
          refresh()
        end
      end)
    end
  end, { buffer = bufnr })
  vim.keymap.set("n", "<CR>", function()
    local row = selected()
    if row and row.section == "tasks" and row.index then
      local task = tasks.items[tasks.order[row.index]]
      if
        not task.outputFilePath
        and not (queue.chat.acp_connection and queue.chat.acp_connection:task_detail_supported("output"))
      then
        vim.notify("Output is unavailable for this task", vim.log.levels.INFO)
        return
      end
      vim.api.nvim_win_close(win, true)
      require("codecompanion.interactions.chat.tasks.output").open({ chat = queue.chat, task = task })
      return
    end
    if not row or row.section ~= "queue" then
      return
    end
    local index = row.index
    local item = queue.items[index]
    if not item or queue.sending then
      return
    end
    if queue.chat.current_request then
      queue.chat:send_now(item.text, function(accepted)
        if accepted then
          queue:change({ index = index, remove = true })
        else
          item.state = "failed"
          item.error = "Correction was not accepted"
          queue:pause("error")
        end
        refresh()
      end)
      return
    end
    queue.sending = item
    item.state = "sending"
    queue:_changed()
    if not queue.chat:send_text(item.text) then
      queue.sending = nil
      item.state = "failed"
      item.error = "Prompt was not accepted"
      queue:pause("error")
    end
    refresh()
  end, { buffer = bufnr })
  vim.keymap.set("n", "s", function()
    local row = selected()
    local task = row and row.section == "tasks" and tasks.items[tasks.order[row.index]]
    if not task or not task.canStop then
      return
    end
    vim.ui.select(
      { "Stop", "Keep running" },
      { prompt = "Stop " .. (task.name or task.asyncTaskId) .. "?" },
      function(choice)
        if choice ~= "Stop" then
          return
        end
        require("codecompanion.utils.async").sync(function()
          local result = queue.chat.acp_connection:send_rpc_request("_session/async_task/stop", {
            sessionId = tasks.session_id,
            asyncTaskId = task.asyncTaskId,
          })
          if result and result.stopped then
            tasks:update({
              sessionUpdate = "async_task_state_update",
              asyncTaskId = task.asyncTaskId,
              state = "stopped",
            })
            vim.schedule(refresh)
          end
        end)()
      end
    )
  end, { buffer = bufnr })
  vim.keymap.set("n", "x", function()
    local row = selected()
    local schedule = row and row.section == "schedules" and tasks.schedules[row.index]
    if schedule then
      queue:add({ text = "Cancel scheduled task " .. schedule.id, origin = "tasks" })
      refresh()
    end
  end, { buffer = bufnr })
  vim.keymap.set("n", "gd", function()
    local row = selected()
    local task = row and row.section == "tasks" and tasks.items[tasks.order[row.index]]
    if not task or not task.toolCallId then
      return
    end
    for mark, id in pairs(queue.chat.tool_call_marks) do
      if id == task.toolCallId then
        local position = vim.api.nvim_buf_get_extmark_by_id(
          queue.chat.bufnr,
          vim.api.nvim_create_namespace("CodeCompanion-tool_calls"),
          mark,
          {}
        )
        if position[1] then
          vim.api.nvim_win_close(win, true)
          vim.api.nvim_set_current_win(queue.chat.ui.winnr)
          vim.api.nvim_win_set_cursor(queue.chat.ui.winnr, { position[1] + 1, 0 })
        end
        return
      end
    end
  end, { buffer = bufnr })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      local row = selected()
      local section = row and row.section or "queue"
      local help = section == "tasks" and "Tasks: <CR> output, s stop, gd tool call"
        or section == "schedules" and "Schedules: x cancel through agent"
        or "Queue: <CR> send, e edit, dd delete, K/J move, P first, p park/queue, r resume"
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { help })
      vim.bo[bufnr].modifiable = false
    end,
  })
end

return M
