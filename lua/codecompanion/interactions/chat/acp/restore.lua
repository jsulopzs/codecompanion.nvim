local utils = require("codecompanion.utils")

local M = {}

---Load an agent session into the chat and render its history in the buffer
---@param chat CodeCompanion.Chat
---@param session_id string
---@param opts? { fork?: boolean, at?: string, title?: string } fork restores a new fork of the session instead, cut after the agent message `at` when given
---@return boolean success
function M.session(chat, session_id, opts)
  opts = opts or {}

  -- The agent replays the history as session updates while the load is in flight
  local updates = {}
  local ok = chat.acp_connection:load_session(session_id, {
    fork = opts.fork,
    at = opts.at,
    on_session_update = function(update)
      table.insert(updates, update)
    end,
  })
  if not ok then
    return false
  end

  require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session(
    chat.bufnr,
    chat.acp_connection.session_id
  )
  require("codecompanion.interactions.chat.acp.render").restore_session(chat, updates)

  if opts.title then
    chat:set_title(opts.title)
  end

  utils.fire("ACPChatRestored", {
    bufnr = chat.bufnr,
    id = chat.id,
    session_id = chat.acp_connection.session_id,
    title = chat.title,
  })

  return true
end

return M
