local checkpoints = require("codecompanion.interactions.chat.acp.checkpoints")
local config = require("codecompanion.config")
local utils = require("codecompanion.utils")

local M = {}
local MAX_CHARS = 12000

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

---Build a bounded transcript that keeps the first user message and the newest exchanges
---@param chat CodeCompanion.Chat
---@return string
function M.build(chat)
  local agent = chat.adapter.name == "codex" and "Codex" or "Claude"
  local intro = "Continúas una conversación que empezó con " .. agent .. ".\n\n"
  local files = changed_files(chat)
  local file_text = #files > 0 and ("\n\nFicheros modificados:\n- " .. table.concat(files, "\n- ")) or ""
  local messages = conversation(chat)
  local first_user
  for index, message in ipairs(messages) do
    if message.role == config.constants.USER_ROLE or message.role == "user" then
      first_user = index
      break
    end
  end
  local budget = math.max(0, MAX_CHARS - #intro - #file_text)
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
  return intro .. table.concat(transcript, "\n\n") .. file_text
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
