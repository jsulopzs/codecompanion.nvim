local M = {}
local namespace = vim.api.nvim_create_namespace("codecompanion_chat_queue")

---@param queue table
function M.render(queue)
  local bufnr = queue.chat.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local lines = {}
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
  local lines = { "Queue - <CR> send now, e edit, dd delete, K/J move, P first, p park/queue, r resume" }
  for index, item in ipairs(queue.items) do
    table.insert(lines, string.format("%d  [%s, %s] %s", index, item.kind, item.state, item.text:gsub("\n", " ")))
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
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
    return vim.api.nvim_win_get_cursor(win)[1] - 1
  end
  local function refresh()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      M.open(queue)
    end
  end
  local function change(opts)
    opts.index = selected()
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
    local item = queue.items[selected()]
    if item then
      change({ kind = item.kind == "parked" and "pending" or "parked" })
    end
  end, { buffer = bufnr })
  vim.keymap.set("n", "e", function()
    local index = selected()
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
    local index = selected()
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
end

return M
