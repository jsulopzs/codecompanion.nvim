local config = require("codecompanion.config")
local M = {}

---Read the select options advertised by the active session
---@param chat CodeCompanion.Chat
---@return table[]
function M.options(chat)
  local connection = chat.acp_connection
  if not connection or not connection.get_config_options or not connection.build_name_map then
    return {}
  end
  local names = connection:build_name_map() or {}
  local options = {}
  for _, option in ipairs(connection:get_config_options()) do
    if option.type == "select" and option.currentValue ~= nil then
      table.insert(options, {
        id = option.id,
        category = option.category,
        label = option.name or option.id,
        value = tostring(option.currentValue),
        name = (names[option.id] or {})[option.currentValue] or tostring(option.currentValue),
      })
    end
  end
  return options
end

---Read the active model's display name
---@param chat CodeCompanion.Chat
---@return string|nil
function M.model(chat)
  if chat.adapter.type == "acp" then
    for _, option in ipairs(M.options(chat)) do
      if option.category == "model" then
        return option.name
      end
    end
    return nil
  end
  return type((chat.settings or {}).model) == "string" and chat.settings.model or nil
end

---Read the settings reported by the chat's current agent
---@param chat CodeCompanion.Chat
---@return table
function M.snapshot(chat)
  local options = {}
  for _, option in ipairs(M.options(chat)) do
    options[option.category or option.id] = option.name
  end
  local function value(category)
    return options[category] or "unknown"
  end
  local model = options.model or M.model(chat)
  local connection = chat.acp_connection
  local role = config.interactions.chat.roles.llm
  local adapter = vim.tbl_extend("keep", chat.adapter, { formatted_name = chat.adapter.name or "unknown" })
  return {
    header = type(role) == "function" and role(adapter) or role,
    provider = chat.adapter.formatted_name or chat.adapter.name or "unknown",
    model = not chat._restoring_session and model and model ~= "default" and model or "unknown",
    effort = chat._restoring_session and "unknown"
      or (value("thought_level") ~= "unknown" and value("thought_level") or value("reasoning_effort")),
    mode = value("mode"),
    connection = chat._changing_adapter and "connecting"
      or (
        connection and type(connection.is_ready) == "function" and connection:is_ready() and "connected"
        or "disconnected"
      ),
  }
end

---Format the identity used for a reply or the active session
---@param session table
---@return string
function M.format(session)
  return string
    .format("%s · %s · effort %s", session.provider or "unknown", session.model or "unknown", session.effort or "unknown")
    :gsub("[\r\n]", " ")
end

---Format the active session's provider, model and effort
---@param chat CodeCompanion.Chat
---@return string
function M.label(chat)
  return M.format(M.snapshot(chat))
end

return M
