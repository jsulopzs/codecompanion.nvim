local async = require("codecompanion.utils.async")
local files = require("codecompanion.utils.files")

local M = {}

---@param opts { chat: CodeCompanion.Chat, task: table, callback: fun(output: string|nil) }
function M.read(opts)
  local connection = opts.chat.acp_connection
  if connection and connection:task_detail_supported("output") then
    async.sync(function()
      local result = connection:send_rpc_request("_session/async_task/output", {
        sessionId = connection.session_id,
        asyncTaskId = opts.task.asyncTaskId,
      })
      opts.callback(result and result.output)
    end)()
    return
  end
  local path = opts.task.outputFilePath
  if not path or not files.exists(path) then
    opts.callback(nil)
    return
  end
  local handle = vim.uv.fs_open(path, "r", 0)
  if not handle then
    opts.callback(nil)
    return
  end
  local size = vim.uv.fs_fstat(handle).size
  local output = vim.uv.fs_read(handle, math.min(size, 8192), math.max(0, size - 8192))
  vim.uv.fs_close(handle)
  opts.callback(output)
end

---@param opts { chat: CodeCompanion.Chat, task: table }
function M.open(opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = false
  local chat_win = opts.chat.ui.winnr
  local width = math.max(1, math.min(100, vim.api.nvim_win_get_width(chat_win) - 4))
  local height = math.max(1, math.min(12, vim.api.nvim_win_get_height(chat_win) - 2))
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "win",
    win = chat_win,
    row = 1,
    col = 1,
    width = width,
    height = height,
    border = "rounded",
    title = { { opts.task.name or "Task output" } },
    title_pos = "center",
    style = "minimal",
  })
  local function refresh()
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    M.read({
      chat = opts.chat,
      task = opts.task,
      callback = function(output)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(
          bufnr,
          0,
          -1,
          false,
          vim.split(output or "Output is unavailable", "\n", { plain = true })
        )
        vim.bo[bufnr].modifiable = false
      end,
    })
    if opts.task.state == "running" or opts.task.state == "paused" then
      vim.defer_fn(refresh, require("codecompanion.config").interactions.chat.tasks.refresh_ms)
    end
  end
  refresh()
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = bufnr })
end

return M
