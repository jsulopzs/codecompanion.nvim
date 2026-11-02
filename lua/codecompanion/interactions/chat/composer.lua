local config = require("codecompanion.config")
local input = require("codecompanion.interactions.shared.input")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local api = vim.api
local ns = api.nvim_create_namespace("codecompanion.composer.hints")
local Composer = {}
Composer.__index = Composer

local function compact_number(value)
  if value >= 1000000 then
    return string.format("%.0fM", value / 1000000)
  end
  if value >= 1000 then
    return string.format("%.0fk", value / 1000)
  end
  return tostring(value)
end

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
  map("n", keys.compact, function()
    chat:compact_context()
  end)
  map("n", "q", function()
    if chat.current_request then
      chat:stop()
    else
      chat.queue:pause("cancelled")
    end
  end)
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = self.bufnr,
    callback = function()
      self:update_status()
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
  vim.wo[self.winnr].winfixheight = true
  self:update_status()
  self:update_height()
  self:dock()
  if api.nvim_win_is_valid(old_win) then
    api.nvim_set_current_win(old_win)
  end
  self.chat.ui:lock_buf()
end

function Composer:dock()
  local chat_win = self.chat.ui.winnr
  if self.docking or not self.chat.ui:is_visible() or not chat_win or not api.nvim_win_is_valid(chat_win) then
    return
  end
  if not self.winnr or not api.nvim_win_is_valid(self.winnr) then
    return
  end
  local chat_position = api.nvim_win_get_position(chat_win)
  local composer_position = api.nvim_win_get_position(self.winnr)
  if
    composer_position[1] == chat_position[1] + api.nvim_win_get_height(chat_win) + 1
    and composer_position[2] == chat_position[2]
    and api.nvim_win_get_width(self.winnr) == api.nvim_win_get_width(chat_win)
  then
    self:update_height()
    return
  end
  self.docking = true
  local ok, err = pcall(api.nvim_win_set_config, self.winnr, { split = "below", win = chat_win })
  self.docking = false
  if not ok then
    log:error("Could not dock the composer: %s", err)
    return
  end
  self:update_height()
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
  -- One more row for the key hints drawn under the text
  local rows = api.nvim_buf_line_count(self.bufnr) + 1
  local height = math.min(settings.max_height, math.max(settings.min_height, rows))
  if api.nvim_win_get_height(self.winnr) ~= height then
    api.nvim_win_set_height(self.winnr, height)
  end
end

---Show the state and what each key does now as a dim line under the text.
---Drawn in the buffer, not the statusline, so a global statusline (laststatus=3) can't hide it
function Composer:update_status()
  if not api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  local keys = config.interactions.chat.composer.keymaps
  local busy = self.chat.current_request ~= nil
  local state = busy and "working" or "ready"
  if self.chat.compacting then
    state = "compacting…"
  end
  if self.chat.queue.paused then
    state = state .. ", queue paused"
  end
  if self.chat.tasks then
    local active, scheduled = self.chat.tasks:counts()
    if active > 0 then
      state = state .. string.format(" · %d %s", active, active == 1 and "task" or "tasks")
    end
    if scheduled > 0 then
      state = state .. string.format(" · %d scheduled", scheduled)
    end
  end
  local hint = string.format(
    "%s · %s %s · %s queue · %s park · %s manage · %s compact%s",
    state,
    keys.send,
    busy and "correct" or "send",
    keys.queue,
    keys.park,
    keys.manager,
    keys.compact,
    busy and " · q stop" or ""
  )
  local segments = { { hint, "Comment" } }
  local usage = self.chat.context_usage
  if usage and type(usage.size) == "number" and usage.size > 0 and type(usage.used) == "number" then
    local ratio = usage.used / usage.size
    local group = ratio >= config.interactions.chat.composer.context_warn and "WarningMsg" or "Comment"
    table.insert(segments, {
      string.format(" · ctx %.0f%% %s/%s", ratio * 100, compact_number(usage.used), compact_number(usage.size)),
      group,
    })
  end
  api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
  api.nvim_buf_set_extmark(self.bufnr, ns, api.nvim_buf_line_count(self.bufnr) - 1, 0, {
    virt_lines = { segments },
  })
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
