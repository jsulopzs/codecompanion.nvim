local async = require("codecompanion.utils.async")
local methods = require("codecompanion.acp.methods")
local utils = require("codecompanion.utils")

local api = vim.api
local M = {}

---Check whether an agent method can start an interactive login without a secret payload
---@param method table
---@return boolean
local function is_agent_login(method)
  if method.type ~= nil and method.type ~= "agent" then
    return false
  end
  local meta = method._meta or {}
  return not method.id:find("api%-key") and meta["api-key"] == nil and meta.gateway == nil
end

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

---Cancel the visible wait for an agent handled login
---@param chat CodeCompanion.Chat
---@return nil
function M.cancel(chat)
  local login = chat._acp_login
  if login then
    login.cancelled = true
    chat._acp_login = nil
    chat:_clear_status()
  end
end

---Ask the agent to start a browser login and reload the session on success
---@param opts { chat: CodeCompanion.Chat, method: table }
---@return nil
function M.run_agent(opts)
  local chat = opts.chat
  local connection = chat.acp_connection
  local login = { cancelled = false }
  chat._acp_login = login
  chat:_set_status({ key = "auth", message = "esperando el login en el navegador… (gL cancela)" })

  async.sync(function()
    local capabilities = connection._agent_info.agentCapabilities or {}
    if capabilities.auth and capabilities.auth.logout then
      local logged_out = connection:send_rpc_request(methods.LOGOUT, {})
      if not logged_out then
        if chat._acp_login == login then
          chat._acp_login = nil
          chat:_clear_status()
          utils.notify("Could not log out before signing in", vim.log.levels.ERROR)
        end
        return
      end
    end
    if login.cancelled then
      return
    end
    local authenticated = connection:send_rpc_request(methods.AUTHENTICATE, { methodId = opts.method.id })
    if chat._acp_login ~= login then
      return
    end
    chat._acp_login = nil
    chat:_clear_status()
    if not authenticated then
      return utils.notify("Login failed or was cancelled", vim.log.levels.ERROR)
    end
    connection.adapter.defaults.auth_method = opts.method.id
    chat.queue:pause("login")
    if not connection:restart_after_login() then
      utils.notify("Login succeeded, but the session could not be reloaded", vim.log.levels.ERROR)
    end
  end)()
end

---Offer the interactive login methods advertised by this ACP agent
---@param chat CodeCompanion.Chat
---@return nil
function M.pick(chat)
  if chat._acp_login then
    M.cancel(chat)
    return
  end
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
    if method.type == "terminal" or is_agent_login(method) then
      table.insert(methods, method)
    end
  end
  if #methods == 0 then
    return utils.notify("This agent does not advertise interactive login methods", vim.log.levels.INFO)
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
    if method.type ~= "terminal" then
      return M.run_agent({ chat = chat, method = method })
    end
    local command = command_for_method({ method = method, connection = connection })
    if not command then
      return utils.notify("This login method has no terminal command", vim.log.levels.ERROR)
    end
    M.run({ chat = chat, command = command, label = method.name or method.id })
  end)
end

return M
