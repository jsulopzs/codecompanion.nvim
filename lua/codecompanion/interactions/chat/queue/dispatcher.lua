local M = {}

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
