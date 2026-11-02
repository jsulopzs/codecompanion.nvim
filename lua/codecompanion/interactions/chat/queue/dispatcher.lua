local M = {}

local function compact_before(queue, item)
  local threshold = require("codecompanion.config").interactions.chat.queue.compact_before
  local usage = queue.chat.context_usage
  if not threshold or item.compaction_requested or not usage or not usage.size or usage.size <= 0 then
    return item
  end
  if usage.used / usage.size <= threshold then
    return item
  end
  local commands = require("codecompanion.interactions.chat.acp.commands").get_commands_for_session(
    queue.chat.acp_connection.session_id
  )
  local command = vim.iter(commands):find(function(available)
    return available.name == "compact"
  end)
  if not command then
    return item
  end
  item.compaction_requested = true
  local compact = {
    id = tostring(vim.uv.hrtime()),
    session_id = queue.session_id,
    kind = "pending",
    state = "pending",
    text = "/" .. command.name,
    origin = "auto_compact",
    created_at = os.time(),
  }
  table.insert(queue.items, item.position, compact)
  queue:_changed()
  return compact
end

---@param text string
---@return string|nil
function M.unexpanded_command(text)
  local commands = require("codecompanion.config").interactions.chat.slash_commands
  for command in (" " .. text):gmatch("%s/([%w_-]+)") do
    if commands[command] and not (command == "file" and text:match("/file%s+[^%s]+")) then
      return command
    end
  end
end

---@param opts { chat: CodeCompanion.Chat, text: string }
---@return string|nil
function M.expand(opts)
  local editor_context = require("codecompanion.config").interactions.shared.editor_context
  local text = opts.text:gsub("#([%w_]+)", function(name)
    return editor_context[name] and ("#{" .. name .. "}") or ("#" .. name)
  end)
  local path = text:match("/file%s+([^%s]+)")
  if path then
    if not require("codecompanion.utils.files").exists(path) then
      return nil
    end
    require("codecompanion.interactions.chat.slash_commands").context(opts.chat, "file", {
      path = vim.fs.normalize(path),
      description = "File from prompt",
    })
  end
  return text
end

---@param queue table
function M.dispatch(queue)
  local chat = queue.chat
  if
    queue.paused
    or queue.sending
    or chat.current_request
    or not chat.acp_connection
    or chat.acp_connection._autonomous_turn
  then
    return
  end
  local item = queue:next_pending()
  if not item or item.state == "failed" then
    return
  end
  item = compact_before(queue, item)
  queue.sending = item
  item.state = "sending"
  queue:_changed()
  local sent = chat:send_text(item.text)
  if not sent then
    queue.sending = nil
    item.state = "failed"
    item.error = "Prompt was not accepted"
    queue:pause()
  end
end

return M
