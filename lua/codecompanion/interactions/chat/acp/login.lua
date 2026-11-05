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

local function auth_request(method)
  local request = { methodId = method.id }
  if is_agent_login(method) and method._meta and method._meta.replaceLogin == true then
    request._meta = { replaceLogin = true }
  end
  return request
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
          require("codecompanion.interactions.chat.acp.account").announce(chat)
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

---Check whether the agent rejected login because another session is active
---@param error_response table|nil
---@return boolean
local function requires_logout(error_response)
  if type(error_response) ~= "table" then
    return false
  end
  local detail = type(error_response.data) == "table" and error_response.data.error or nil
  local message = (tostring(error_response.message or "") .. " " .. tostring(detail or "")):lower()
  return message:find("already authenticated", 1, true) ~= nil
    or message:find("already logged in", 1, true) ~= nil
    or message:find("already signed in", 1, true) ~= nil
    or message:find("session already active", 1, true) ~= nil
end

---Ask before replacing the agent's current account
---@param opts { chat: CodeCompanion.Chat, login: table }
---@return boolean
local function confirm_logout(opts)
  local choice = async.wait(function(callback)
    vim.ui.select({ "Cerrar la sesión actual y continuar", "Cancelar" }, {
      kind = "codecompanion.nvim",
      prompt = "El agente requiere cerrar la sesión actual",
    }, callback)
  end)
  return choice == "Cerrar la sesión actual y continuar" and opts.chat._acp_login == opts.login
end

---Finish an agent login, leaving the chat open if it failed or was cancelled
---@param opts { chat: CodeCompanion.Chat, connection: CodeCompanion.ACP.Connection, login: table, method: table, authenticated: table|nil }
---@return nil
local function finish_agent_login(opts)
  if opts.chat._acp_login ~= opts.login then
    return
  end
  opts.chat._acp_login = nil
  opts.chat:_clear_status()
  if opts.login.cancelled then
    return
  end
  if not opts.authenticated then
    return utils.notify("Login failed or was cancelled", vim.log.levels.ERROR)
  end
  opts.connection.adapter.defaults.auth_method = opts.method.id
  opts.chat.queue:pause("login")
  if not opts.connection:restart_after_login() then
    utils.notify("Login succeeded, but the session could not be reloaded", vim.log.levels.ERROR)
  end
  require("codecompanion.interactions.chat.acp.account").announce(opts.chat)
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
    local authenticated, error_response = connection:send_rpc_request(methods.AUTHENTICATE, auth_request(opts.method))
    local capabilities = connection._agent_info.agentCapabilities or {}
    if
      not authenticated
      and not login.cancelled
      and requires_logout(error_response)
      and capabilities.auth
      and capabilities.auth.logout
    then
      if confirm_logout({ chat = chat, login = login }) then
        local logged_out = connection:send_rpc_request(methods.LOGOUT, {})
        if logged_out and not login.cancelled then
          chat:_set_status({ key = "auth", message = "esperando el login en el navegador… (gL cancela)" })
          authenticated = connection:send_rpc_request(methods.AUTHENTICATE, auth_request(opts.method))
        end
      else
        login.cancelled = true
      end
    end
    finish_agent_login({
      chat = chat,
      connection = connection,
      login = login,
      method = opts.method,
      authenticated = authenticated,
    })
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
  local can_replace_login = false
  for _, method in ipairs(methods) do
    if is_agent_login(method) and method._meta and method._meta.replaceLogin == true then
      can_replace_login = true
      break
    end
  end

  vim.ui.select(methods, {
    kind = "codecompanion.nvim",
    prompt = can_replace_login and "Log in with (current session stays active until the new login completes)"
      or "Log in with",
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
