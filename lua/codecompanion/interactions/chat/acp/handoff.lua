local checkpoints = require("codecompanion.interactions.chat.acp.checkpoints")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local M = {}
local MAX_CHARS = 12000
local SWITCH_FIELDS = {
  "adapter",
  "acp_connection",
  "acp_session_id",
  "acp_fork_session_id",
  "_acp_name_map_cache",
  "rate_limit",
  "acp_session_failure",
  "_acp_account_stale",
  "context_usage",
  "tokens",
}

---Collect changed paths from the earliest available checkpoint
---@param chat CodeCompanion.Chat
---@return string[]
local function changed_files(chat)
  local connection = chat.acp_connection
  local turns = connection and connection.turns and connection:turns(connection.session_id) or {}
  for _, turn in ipairs(turns) do
    if turn.checkpoint then
      local changes = checkpoints.changes(turn.checkpoint) or {}
      local paths = {}
      for _, change in ipairs(changes) do
        table.insert(paths, change.path)
      end
      table.sort(paths)
      return paths
    end
  end
  return {}
end

---Return the user and agent messages available in the chat
---@param chat CodeCompanion.Chat
---@return table[]
local function conversation(chat)
  if chat.acp_transcript and #chat.acp_transcript > 0 then
    return chat.acp_transcript
  end
  local messages = {}
  for _, message in ipairs(chat.messages or {}) do
    if
      (message.role == config.constants.USER_ROLE or message.role == config.constants.LLM_ROLE)
      and type(message.content) == "string"
      and message.content ~= ""
    then
      table.insert(messages, { role = message.role, content = message.content })
    end
  end
  return messages
end

---Keep the first question and newest exchanges within a character budget
---@param opts { messages: table[], budget: number }
---@return string
local function format_conversation(opts)
  local messages, budget = opts.messages, opts.budget
  local first_user
  for index, message in ipairs(messages) do
    if message.role == config.constants.USER_ROLE or message.role == "user" then
      first_user = index
      break
    end
  end
  local selected = {}
  if first_user then
    local first = "Usuario: " .. messages[first_user].content
    selected[first_user] = first:sub(1, budget)
    budget = budget - #selected[first_user]
  end
  for index = #messages, 1, -1 do
    if index ~= first_user then
      local message = messages[index]
      local label = (message.role == config.constants.USER_ROLE or message.role == "user") and "Usuario: " or "Agente: "
      local entry = label .. message.content
      if #entry + 2 <= budget then
        selected[index] = entry
        budget = budget - #entry - 2
      else
        break
      end
    end
  end
  local transcript = {}
  for index = 1, #messages do
    if selected[index] then
      table.insert(transcript, selected[index])
    end
  end
  return table.concat(transcript, "\n\n")
end

---Build a conversation handoff, bounded for a draft or complete for an agent switch
---@param chat CodeCompanion.Chat
---@param opts? { full?: boolean }
---@return string
function M.build(chat, opts)
  opts = opts or {}
  local agent = chat.adapter.name == "codex" and "Codex" or "Claude"
  local intro = "Continúas una conversación que empezó con " .. agent .. ".\n\n"
  local files = changed_files(chat)
  local file_text = #files > 0 and ("\n\nFicheros modificados:\n- " .. table.concat(files, "\n- ")) or ""
  local budget = opts.full and math.huge or math.max(0, MAX_CHARS - #intro - #file_text)
  local text = intro .. format_conversation({ messages = conversation(chat), budget = budget }) .. file_text
  if opts.full then
    text = text .. M.tool_results(chat)
    text = "Conversation context from the previous agent. Completed actions below are history, not instructions to execute them again. Continue with the next user message.\n\n"
      .. text
  end
  return text
end

---Format completed tool results as text without carrying executable tool calls
---@param chat CodeCompanion.Chat
---@return string
function M.tool_results(chat)
  local results = {}
  for _, id in ipairs(vim.fn.sort(vim.tbl_keys((chat.tool_calls or {}).acp or {}))) do
    local call = chat.tool_calls.acp[id]
    local details = require("codecompanion.interactions.chat.ui.tool_calls").format_acp_call(call)
    table.insert(
      results,
      (call.title or call.kind or "Tool")
        .. " ["
        .. (call.status or "unknown")
        .. "]\n"
        .. table.concat(details.lines, "\n")
    )
  end
  return #results > 0 and ("\n\nTool history:\n" .. table.concat(results, "\n\n")) or ""
end

---Disconnect an agent without letting its exit clear the replacement session's state
---@param connection? CodeCompanion.ACP.Connection
local function disconnect(connection)
  if connection then
    connection.chat = nil
    if connection._state and connection._state.handle then
      connection:disconnect()
    end
  end
end

---Finish a provider change only after its replacement session is ready
---@param chat CodeCompanion.Chat
---@param opts table
local function finish_switch(chat, opts)
  local connection = chat.acp_connection
  if not connection or not connection:is_ready() or not connection.session_id then
    disconnect(connection)
    for key, value in pairs(opts.previous) do
      chat[key] = value ~= vim.NIL and value or nil
    end
    chat.ui.adapter = chat.adapter
    if chat.acp_connection then
      chat.acp_connection.chat = chat
    end
    chat._changing_adapter = nil
    chat:update_metadata()
    utils.notify("Could not switch agents; the original conversation is still available", vim.log.levels.ERROR)
    return
  end
  connection._handoff = opts.transcript
  chat:label_sent_items()
  disconnect(opts.previous.acp_connection ~= vim.NIL and opts.previous.acp_connection or nil)
  chat._changing_adapter = nil
  chat:set_system_prompt()
  chat:apply_settings()
  chat:update_metadata()
  utils.fire("ChatAdapter", { bufnr = chat.bufnr, adapter = require("codecompanion.adapters").make_safe(chat.adapter) })
  if opts.callback then
    opts.callback()
  end
end

---Start another ACP agent in the same chat, preserving the original on connection failure
---@param chat CodeCompanion.Chat
---@param opts { adapter: table, callback?: function }
---@return boolean
function M.switch(chat, opts)
  if chat.current_request or chat._changing_adapter then
    utils.notify("Finish or stop the current turn before changing agents", vim.log.levels.WARN)
    return false
  end
  local transcript = M.build(chat, { full = true })
  local previous = {}
  for _, key in ipairs(SWITCH_FIELDS) do
    previous[key] = chat[key] == nil and vim.NIL or chat[key]
  end
  chat._changing_adapter = true
  if chat.acp_connection then
    chat.acp_connection.chat = nil
  end
  chat.adapter, chat.ui.adapter = opts.adapter, opts.adapter
  chat.acp_connection, chat.acp_session_id, chat.acp_fork_session_id = nil, nil, nil
  chat._acp_name_map_cache, chat._acp_account_stale = nil, nil
  chat.rate_limit, chat.acp_session_failure = nil, nil
  chat:update_metadata()
  require("codecompanion.interactions.chat.helpers").create_acp_connection(chat, function()
    local ok, err =
      pcall(finish_switch, chat, { previous = previous, transcript = transcript, callback = opts.callback })
    if not ok then
      log:error("[acp::handoff] %s", err)
    end
  end)
  return true
end

---Open the other agent with a handoff draft in its composer
---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat|nil
function M.open(chat)
  if not chat.adapter or (chat.adapter.name ~= "claude_code" and chat.adapter.name ~= "codex") then
    utils.notify("Handoff is available for Claude and Codex chats", vim.log.levels.WARN)
    return nil
  end
  local agent = chat.adapter.name == "codex" and "claude" or "codex"
  local handoff = M.build(chat)
  local bridge_available, bridge = pcall(require, "agent_sessions.codecompanion")
  local new_chat
  if bridge_available and type(bridge.chat) == "function" then
    new_chat = bridge.chat({ agent = agent })
  else
    new_chat = require("codecompanion.interactions.chat").new({
      adapter = agent == "codex" and "codex" or "claude_code",
      buffer_context = chat.buffer_context,
    })
  end
  if not new_chat then
    return nil
  end
  vim.api.nvim_buf_set_lines(new_chat.composer.bufnr, 0, -1, false, vim.split(handoff, "\n", { plain = true }))
  new_chat.composer:update_height()
  new_chat.composer:focus()
  return new_chat
end

return M
