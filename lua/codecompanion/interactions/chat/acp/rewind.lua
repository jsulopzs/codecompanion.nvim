local checkpoints = require("codecompanion.interactions.chat.acp.checkpoints")
local utils = require("codecompanion.utils")

local M = {}

---Can the chat rewind?
---@param chat CodeCompanion.Chat
---@return boolean, string
function M.enabled(chat)
  local conn = chat.acp_connection
  if not conn or not conn.session_id then
    return false, "Rewinding needs an agent session"
  end
  if not conn:can_fork_session() then
    return false, "This agent does not support forking sessions"
  end
  if not conn:can_load_session() then
    return false, "This agent does not support loading sessions"
  end
  return true, ""
end

---Put a prompt back in the chat buffer to edit and resend
---@param chat CodeCompanion.Chat
---@param prompt string
---@return nil
local function refill(chat, prompt)
  -- The restored history is still queued in the builder, so write it out before the prompt goes after it
  chat.builder:flush()
  local lines = vim.split(prompt, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(chat.bufnr, -1, -1, false, lines)
  if chat.ui:is_visible() then
    vim.api.nvim_win_set_cursor(chat.ui.winnr, { vim.api.nvim_buf_line_count(chat.bufnr), 0 })
  end
end

---Rewind the chat to just before one of its turns: the chat continues in a fork of the session cut after the
---previous turn's reply, the original session stays as it was, and the chosen prompt is back in the buffer
---Rewinding to the first turn starts a new session
---@param chat CodeCompanion.Chat
---@param index number The turn to rewind to, oldest first
---@param opts? { files?: CodeCompanion.ACP.CheckpointChange[] } files are changes since the turn's checkpoint to undo too
---@return boolean success
function M.to(chat, index, opts)
  opts = opts or {}
  local ok, reason = M.enabled(chat)
  if not ok then
    utils.notify(reason, vim.log.levels.WARN)
    return false
  end
  if chat.current_request then
    utils.notify("Stop the current request before rewinding", vim.log.levels.WARN)
    return false
  end

  local conn = chat.acp_connection
  local source = conn.session_id
  local turns = conn:turns(source)
  local turn = turns[index]
  if not turn then
    return false
  end

  local restore = require("codecompanion.interactions.chat.acp.restore")
  if index == 1 then
    conn:use_session(nil)
    if not conn:ensure_session() then
      utils.notify("Could not start a new session", vim.log.levels.ERROR)
      conn:use_session(source)
      return false
    end
    require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session(chat.bufnr, conn.session_id)
    require("codecompanion.interactions.chat.acp.render").restore_session(chat, {})
  else
    local cut = turns[index - 1].agent_message_id
    if not cut then
      utils.notify("The earlier turn has no reply to rewind to", vim.log.levels.WARN)
      return false
    end
    if not restore.session(chat, source, { fork = true, at = cut }) then
      utils.notify("Could not rewind the session", vim.log.levels.ERROR)
      restore.session(chat, source)
      return false
    end
    -- An agent that ignores the cut forks the whole session, so check where the fork really ends
    local forked = conn:turns(conn.session_id)
    local last = forked[#forked]
    if not last or last.agent_message_id ~= cut then
      utils.notify("The agent did not cut the session where asked, so it stays as it was", vim.log.levels.WARN)
      restore.session(chat, source)
      return false
    end
  end

  -- The fork's turns came from the replayed history, which knows nothing of the checkpoints taken before each prompt
  local rewound = conn:turns(conn.session_id)
  for i = 1, index - 1 do
    if rewound[i] then
      rewound[i].checkpoint = turns[i].checkpoint
    end
  end

  if opts.files and #opts.files > 0 and turn.checkpoint then
    if checkpoints.restore(turn.checkpoint, opts.files) then
      utils.notify(("Restored %d file(s)"):format(#opts.files), vim.log.levels.INFO)
    else
      utils.notify("Some files could not be restored", vim.log.levels.WARN)
    end
  end

  refill(chat, turn.prompt)
  utils.fire("ACPChatRewound", {
    bufnr = chat.bufnr,
    id = chat.id,
    session_id = conn.session_id,
    source_session_id = source,
  })
  return true
end

---Pick a turn to rewind to
---@param chat CodeCompanion.Chat
---@return nil
function M.pick(chat)
  local ok, reason = M.enabled(chat)
  if not ok then
    return utils.notify(reason, vim.log.levels.WARN)
  end

  local turns = chat.acp_connection:turns(chat.acp_connection.session_id)
  if #turns == 0 then
    return utils.notify("Nothing to rewind to", vim.log.levels.INFO)
  end

  -- Newest first: the usual target is a step or two back
  local choices = {}
  for index = #turns, 1, -1 do
    local first_line = vim.trim(vim.split(turns[index].prompt, "\n", { plain = true })[1] or "")
    table.insert(choices, { index = index, label = first_line ~= "" and first_line or "(no text)" })
  end

  vim.ui.select(choices, {
    prompt = "Rewind to",
    kind = "codecompanion.nvim",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      M.choose_files(chat, choice.index)
    end
  end)
end

---Summarise changed files for a one-line prompt
---@param changes CodeCompanion.ACP.CheckpointChange[]
---@return string
local function describe(changes)
  local shown = vim.tbl_map(function(change)
    return (change.status == "A" and "+" or change.status == "D" and "-" or "~") .. change.path
  end, vim.list_slice(changes, 1, 3))
  local rest = #changes > 3 and (" and %d more"):format(#changes - 3) or ""
  return table.concat(shown, ", ") .. rest
end

---Rewind to a turn, first asking whether to restore the files changed since it when there are any
---@param chat CodeCompanion.Chat
---@param index number
---@return nil
function M.choose_files(chat, index)
  local turn = chat.acp_connection:turns(chat.acp_connection.session_id)[index]
  local changes = turn and turn.checkpoint and checkpoints.changes(turn.checkpoint)
  if not changes or #changes == 0 then
    M.to(chat, index)
    return
  end

  vim.ui.select({
    { files = changes, label = ("Conversation and files (%d): %s"):format(#changes, describe(changes)) },
    { label = "Conversation only" },
  }, {
    prompt = "Files changed since then. Restore them too?",
    kind = "codecompanion.nvim",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      M.to(chat, index, { files = choice.files })
    end
  end)
end

return M
