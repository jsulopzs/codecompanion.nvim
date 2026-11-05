local async = require("codecompanion.utils.async")
local files = require("codecompanion.utils.files")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local api = vim.api
local uv = vim.uv

local M = {}

---The last login each agent was reloaded for in this Neovim, keyed by adapter name
---@type table<string, string|false>
local seen = {}
local watcher

---@return string
function M._signal_dir()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codecompanion", "acp_logins")
end

---@param agent string
---@return string
local function signal_path(agent)
  return vim.fs.joinpath(M._signal_dir(), agent .. ".json")
end

---@param agent string
---@return { id: string }|nil
local function read_signal(agent)
  local read, content = pcall(files.read, signal_path(agent))
  if not read then
    return nil
  end
  local decoded, signal = pcall(vim.json.decode, content)
  if decoded and type(signal) == "table" and type(signal.id) == "string" then
    return signal
  end
end

---Check whether the agent has stopped this chat until it logs in or its limit resets
---@param chat CodeCompanion.Chat
---@return boolean
local function is_blocked(chat)
  local failure = chat.acp_session_failure
  if failure and vim.tbl_contains(failure.actions or {}, "login") then
    return true
  end
  local limit = chat.rate_limit
  return limit ~= nil
    and limit.status ~= "allowed"
    and type(limit.resetsAt) == "number"
    and limit.resetsAt > os.time()
end

---Restart a chat's agent so it picks up the account another chat logged in with
---@param chat CodeCompanion.Chat
---@return boolean
function M.reload(chat)
  chat._acp_account_stale = nil
  if not chat.acp_connection:restart_after_login({ quiet = true }) then
    log:error("[acp::account] Could not reload %s with the new login", chat.title or chat.bufnr)
    return false
  end
  -- Both described the old account
  chat.rate_limit = nil
  chat.acp_session_failure = nil
  if chat.composer then
    chat.composer:update_status()
  end
  return true
end

---Reload a chat the old account had blocked, then retry the prompt that failed
---@param chat CodeCompanion.Chat
---@return boolean
local function unblock(chat)
  if not M.reload(chat) then
    return false
  end
  if chat.queue and chat.queue.paused and chat.queue.paused_reason == "error" then
    chat.queue:resume()
  end
  return true
end

---Move this Neovim's other chats of an agent onto its new login
---@param opts { agent: string, except?: CodeCompanion.Chat }
---@return nil
function M.apply(opts)
  local blocked = {}
  for _, entry in ipairs(require("codecompanion.interactions.chat").buf_get_chat()) do
    local chat = entry.chat
    local connection = chat.acp_connection
    if
      chat ~= opts.except
      and connection
      and connection.adapter
      and connection.adapter.name == opts.agent
      and connection._state.handle
      and connection.session_id
    then
      chat._acp_account_stale = true
      if not chat.current_request and is_blocked(chat) then
        table.insert(blocked, chat)
      end
    end
  end
  if #blocked == 0 then
    return
  end

  -- One at a time, so a login does not start every blocked agent at once
  async.sync(function()
    local reloaded = 0
    for _, chat in ipairs(blocked) do
      if chat._acp_account_stale and not chat.current_request and unblock(chat) then
        reloaded = reloaded + 1
      end
    end
    if reloaded > 0 then
      utils.notify(("Nueva cuenta aplicada a %d chat(s) bloqueado(s) de %s"):format(reloaded, opts.agent))
    end
  end)()
end

---Reload the chats of every watched agent that logged in from another chat or Neovim
---@return nil
function M.check()
  for agent, id in pairs(seen) do
    local signal = read_signal(agent)
    if signal and signal.id ~= id then
      seen[agent] = signal.id
      M.apply({ agent = agent })
    end
  end
end

---Follow logins of an agent, from this or any other Neovim
---@param agent string
---@return nil
function M.watch(agent)
  if seen[agent] == nil then
    local signal = read_signal(agent)
    seen[agent] = signal and signal.id or false
  end
  if watcher then
    return
  end

  local dir = M._signal_dir()
  vim.fn.mkdir(dir, "p")
  watcher = uv.new_fs_event()
  local started, error_message = watcher:start(dir, {}, function()
    vim.schedule(M.check)
  end)
  if not started then
    log:error("[acp::account] Could not watch %s: %s", dir, error_message)
  end
  -- A Neovim that was suspended can miss the file event
  api.nvim_create_autocmd("FocusGained", {
    group = api.nvim_create_augroup("codecompanion.acp.account", { clear = true }),
    callback = M.check,
  })
end

---Tell every chat of this agent, in any Neovim, that a chat logged in with a new account
---@param chat CodeCompanion.Chat
---@return nil
function M.announce(chat)
  local adapter = chat.acp_connection.adapter
  local agent = adapter and adapter.name
  if not agent then
    return
  end
  local id = ("%d-%d"):format(uv.os_getpid(), uv.hrtime())
  seen[agent] = id

  local path = signal_path(agent)
  local temporary = path .. "." .. uv.os_getpid() .. ".tmp"
  -- Renamed into place, so a watcher never reads a half written file
  local written = pcall(files.write_to_path, temporary, vim.json.encode({ id = id, time = os.time() }))
  if not written or not uv.fs_rename(temporary, path) then
    log:error("[acp::account] Could not share the new %s login", agent)
  end

  M.apply({ agent = agent, except = chat })
end

return M
