local config = require("codecompanion.config")
local input = require("codecompanion.interactions.shared.input")
local utils = require("codecompanion.utils")

local api = vim.api
local Composer = {}
Composer.__index = Composer

---@param chat CodeCompanion.Chat
---@return table
function Composer.new(chat)
  local self = setmetatable({ chat = chat, bufnr = api.nvim_create_buf(false, true), winnr = nil }, Composer)
  api.nvim_buf_set_name(self.bufnr, string.format("[CodeCompanion Composer] %d", chat.bufnr))
  input.configure_buffer(self.bufnr)
  vim.b[self.bufnr].codecompanion_chat_bufnr = chat.bufnr
  vim.bo[self.bufnr].buftype = "acwrite"
  local keys = config.interactions.chat.composer.keymaps
  local function map(modes, key, callback)
    vim.keymap.set(modes, key, callback, { buffer = self.bufnr, silent = true })
  end
  map({ "i", "n" }, keys.send, function()
    self:send("now")
  end)
  map("n", "<CR>", function()
    self:send("now")
  end)
  map({ "i", "n" }, keys.queue, function()
    self:send("queue")
  end)
  map("n", keys.park, function()
    self:send("parked")
  end)
  map("n", keys.manager, function()
    require("codecompanion.interactions.chat.queue.view").open(chat.queue)
  end)
  map("n", "q", function()
    if chat.current_request then
      chat:stop()
    else
      chat.queue:pause("cancelled")
    end
  end)
  api.nvim_create_autocmd("TextChangedI", {
    buffer = self.bufnr,
    callback = function()
      self:update_height()
    end,
  })
  return self
end

function Composer:open()
  if self.winnr and api.nvim_win_is_valid(self.winnr) then
    return
  end
  if not self.chat.ui:is_visible() then
    return
  end
  local old_win = api.nvim_get_current_win()
  self.winnr = api.nvim_open_win(self.bufnr, false, {
    split = "below",
    win = self.chat.ui.winnr,
    height = config.interactions.chat.composer.min_height,
  })
  vim.wo[self.winnr].wrap = true
  self:update_status()
  self:update_height()
  if api.nvim_win_is_valid(old_win) then
    api.nvim_set_current_win(old_win)
  end
  self.chat.ui:lock_buf()
end

function Composer:hide()
  if self.winnr and api.nvim_win_is_valid(self.winnr) then
    api.nvim_win_close(self.winnr, true)
  end
  self.winnr = nil
end

function Composer:close()
  self:hide()
  if api.nvim_buf_is_valid(self.bufnr) then
    api.nvim_buf_delete(self.bufnr, { force = true })
  end
end

function Composer:focus()
  self:open()
  if self.winnr and api.nvim_win_is_valid(self.winnr) then
    api.nvim_set_current_win(self.winnr)
    vim.cmd("startinsert")
  end
end

function Composer:update_height()
  if not self.winnr or not api.nvim_win_is_valid(self.winnr) then
    return
  end
  local settings = config.interactions.chat.composer
  local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  api.nvim_win_set_height(self.winnr, math.min(settings.max_height, math.max(settings.min_height, #lines)))
end

function Composer:update_status()
  if not self.winnr or not api.nvim_win_is_valid(self.winnr) then
    return
  end
  local queue = self.chat.queue
  local busy = self.chat.current_request ~= nil
  local state = busy and "working" or "ready"
  if queue.paused then
    state = state .. ", queue paused"
  end
  vim.wo[self.winnr].statusline = string.format(
    " Composer: %s | Ctrl-S %s | Alt-Enter queue | gp park | gQ manage ",
    state,
    busy and "correct" or "send"
  )
end

---@param kind "now"|"queue"|"parked"
function Composer:send(kind)
  local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return
  end
  local accepted
  if kind == "queue" and not self.chat.queue:allows(text) then
    utils.notify("/rewind and /resume must run now", vim.log.levels.WARN)
    return
  end
  if kind == "now" then
    accepted = self.chat:send_now(text)
  elseif kind == "queue" and not self.chat.current_request and not self.chat.queue:next_pending() then
    accepted = self.chat:send_text(text)
  else
    accepted = self.chat.queue:add({ text = text, kind = kind == "parked" and "parked" or "pending" }) ~= nil
  end
  if accepted then
    api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { "" })
    vim.bo[self.bufnr].modified = false
    self:update_height()
    self:update_status()
  else
    utils.notify("Prompt was not accepted", vim.log.levels.WARN)
  end
end

return Composer
