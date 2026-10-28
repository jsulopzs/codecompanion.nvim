local rewind = require("codecompanion.interactions.chat.acp.rewind")

---@class CodeCompanion.SlashCommand.Rewind: CodeCompanion.SlashCommand
local SlashCommand = {}

---@param args CodeCompanion.SlashCommand
function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
end

---Is the slash command enabled?
---@param chat CodeCompanion.Chat
---@return boolean,string
function SlashCommand.enabled(chat)
  return rewind.enabled(chat)
end

---Execute the slash command
---@return nil
function SlashCommand:execute()
  rewind.pick(self.Chat)
end

return SlashCommand
