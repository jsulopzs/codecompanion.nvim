local async = require("codecompanion.utils.async")
local utils = require("codecompanion.utils")

local api = vim.api
local M = {}

---Resolve the terminal command advertised by an ACP auth method
---@param opts { method: table, connection: CodeCompanion.ACP.Connection }
---@return string[]|nil
local function command_for_method(opts)
  local terminal = opts.method._meta and opts.method._meta["terminal-auth"]
  if terminal and type(terminal.command) == "string" then
    return vim.list_extend({ terminal.command }, terminal.args or {})
  end
  local executable = opts.connection.adapter_modified and opts.connection.adapter_modified.command
  if executable and opts.method.args then
    return vim.list_extend(vim.deepcopy(executable), opts.method.args)
  end
end

---Run an advertised login command in a floating terminal over the chat
---@param opts { chat: CodeCompanion.Chat, command: string[], label: string }
---@return nil
function M.run(opts)
  local chat = opts.chat
  local width = math.max(20, math.floor(api.nvim_win_get_width(chat.ui.winnr) * 0.9))
  local height = math.max(5, math.floor(api.nvim_win_get_height(chat.ui.winnr) * 0.8))
  local bufnr = api.nvim_create_buf(false, true)
  local previous_window = api.nvim_get_current_win()
  local winnr = api.nvim_open_win(bufnr, true, {
    relative = "win",
    win = chat.ui.winnr,
    row = 1,
    col = 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = opts.label,
  })
  local cancelled = false
  local job_id
  local function cancel()
    cancelled = true
    if job_id then
      vim.fn.jobstop(job_id)
    end
    if api.nvim_win_is_valid(winnr) then
      api.nvim_win_close(winnr, true)
    end
  end
  vim.keymap.set({ "n", "t" }, "<C-c>", cancel, { buffer = bufnr })
  vim.keymap.set("n", "q", cancel, { buffer = bufnr })
  job_id = vim.fn.termopen(opts.command, {
    cwd = vim.fn.getcwd(),
    on_exit = function(_, code)
      vim.schedule(function()
        if api.nvim_win_is_valid(winnr) then
          api.nvim_win_close(winnr, true)
        end
        if api.nvim_win_is_valid(previous_window) then
          api.nvim_set_current_win(previous_window)
        end
        if cancelled then
          return
        end
        if code ~= 0 then
          utils.notify("Login failed", vim.log.levels.ERROR)
          return
        end
        chat.queue:pause("login")
        async.sync(function()
          if not chat.acp_connection:restart_after_login() then
            utils.notify("Login succeeded, but the session could not be reloaded", vim.log.levels.ERROR)
          end
        end)()
      end)
    end,
  })
  vim.cmd("startinsert")
end

---Offer the terminal login methods advertised by this ACP agent
---@param chat CodeCompanion.Chat
---@return nil
function M.pick(chat)
  local connection = chat.acp_connection
  if not connection or not connection._agent_info then
    return utils.notify("Connect to an ACP agent before logging in", vim.log.levels.WARN)
  end
  if chat.current_request then
    return utils.notify("Stop the current request before logging in", vim.log.levels.WARN)
  end
  if not connection.session_id or not connection:can_load_session() then
    return utils.notify("This agent cannot reload the current session", vim.log.levels.WARN)
  end

  local methods = {}
  for _, method in ipairs(connection._agent_info.authMethods or {}) do
    if method.type == "terminal" then
      table.insert(methods, method)
    end
  end
  if #methods == 0 then
    return utils.notify("This agent does not advertise terminal login methods", vim.log.levels.INFO)
  end

  vim.ui.select(methods, {
    kind = "codecompanion.nvim",
    prompt = "Log in with",
    format_item = function(method)
      return method.name or method.id
    end,
  }, function(method)
    if not method then
      return
    end
    local command = command_for_method({ method = method, connection = connection })
    if not command then
      return utils.notify("This login method has no terminal command", vim.log.levels.ERROR)
    end
    M.run({ chat = chat, command = command, label = method.name or method.id })
  end)
end

return M
