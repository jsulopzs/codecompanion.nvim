local config = require("codecompanion.config")
local store = require("codecompanion.interactions.chat.queue.store")

local Queue = {}
Queue.__index = Queue

---@param chat CodeCompanion.Chat
---@return table
function Queue.new(chat)
  local self = setmetatable({
    chat = chat,
    items = {},
    paused = false,
    paused_reason = nil,
    sending = nil,
    session_id = nil,
    resume_session_id = chat.acp_session_id,
    fork_session_id = chat.acp_fork_session_id,
  }, Queue)
  vim.api.nvim_buf_attach(chat.bufnr, false, {
    on_lines = function()
      if self._view_scheduled then
        return
      end
      self._view_scheduled = true
      vim.schedule(function()
        self._view_scheduled = false
        require("codecompanion.interactions.chat.queue.view").render(self)
      end)
    end,
  })
  return self
end

function Queue:_changed()
  for index, item in ipairs(self.items) do
    item.position = index
  end
  if self.session_id and config.interactions.chat.queue.save then
    store.save({
      session_id = self.session_id,
      value = {
        session_id = self.session_id,
        adapter = self.chat.adapter and self.chat.adapter.name,
        paused = self.paused,
        paused_reason = self.paused_reason,
        updated_at = os.time(),
        items = self.items,
      },
    })
  end
  require("codecompanion.interactions.chat.queue.view").render(self)
  if self.chat.composer then
    self.chat.composer:update_status()
  end
end

---@param text string
---@return boolean
function Queue:allows(text)
  local command = text:match("^%s*/([%w_]+)")
  return command ~= "rewind" and command ~= "resume"
end

---@param session_id string
function Queue:attach(session_id)
  if self.session_id == session_id then
    return
  end
  local previous = self.session_id
  local saved = config.interactions.chat.queue.save and store.load({ session_id = session_id }) or nil
  self.session_id = session_id
  if previous then
    self.paused = true
    self.paused_reason = "session_changed"
  elseif saved then
    self.items = saved.items or {}
    self.paused = self.resume_session_id ~= nil or saved.paused or false
    self.paused_reason = self.resume_session_id and "resumed" or saved.paused_reason
  elseif self.fork_session_id and config.interactions.chat.queue.save then
    local parent = store.load({ session_id = self.fork_session_id })
    if parent then
      self.items = parent.items or {}
      self.paused = true
      self.paused_reason = "forked"
    end
  end
  for _, item in ipairs(self.items) do
    item.session_id = session_id
    if item.state == "sending" then
      item.state = "failed"
      item.error = "Turn ended before confirmation"
      self.paused = true
      self.paused_reason = "error"
    end
  end
  self:_changed()
  if not self.paused then
    vim.schedule(function()
      self:dispatch()
    end)
  end
end

---@param opts { text: string, kind?: "pending"|"parked", origin?: string }
---@return table|nil
function Queue:add(opts)
  if not self:allows(opts.text) then
    vim.notify("/rewind and /resume must run now", vim.log.levels.WARN)
    return nil
  end
  local command = require("codecompanion.interactions.chat.queue.dispatcher").unexpanded_command(opts.text)
  if command then
    vim.notify("/" .. command .. " will be sent as text when this prompt leaves the queue", vim.log.levels.WARN)
  end
  local item = {
    id = tostring(vim.uv.hrtime()),
    session_id = self.session_id,
    position = #self.items + 1,
    kind = opts.kind or "pending",
    state = "pending",
    text = opts.text,
    origin = opts.origin or "composer",
    created_at = os.time(),
  }
  table.insert(self.items, item)
  self:_changed()
  if item.kind == "pending" then
    self:dispatch()
  end
  return item
end

function Queue:next_pending()
  for _, item in ipairs(self.items) do
    if item.kind == "pending" then
      return item
    end
  end
end

function Queue:dispatch()
  require("codecompanion.interactions.chat.queue.dispatcher").dispatch(self)
end

function Queue:mark_accepted()
  local item = self.sending
  if not item or item.state == "sent" then
    return
  end
  for index, queued in ipairs(self.items) do
    if queued == item then
      table.remove(self.items, index)
      break
    end
  end
  item.state = "sent"
  item.sent_at = os.time()
  self:_changed()
end

---@param opts { reason?: string, error?: string }
function Queue:turn_finished(opts)
  local item = self.sending
  if item and opts.reason == "end_turn" and not opts.error then
    self:mark_accepted()
  end
  self.sending = nil
  if item and item.state ~= "sent" then
    item.state = "failed"
    item.error = opts.error or opts.reason or "Turn did not finish normally"
    self.paused = true
    self.paused_reason = opts.reason or "error"
  end
  if opts.error or (opts.reason and opts.reason ~= "end_turn") then
    self.paused = true
    self.paused_reason = opts.reason or "error"
  end
  self:_changed()
  if not self.paused then
    vim.schedule(function()
      self:dispatch()
    end)
  end
end

function Queue:resume()
  self.paused = false
  self.paused_reason = nil
  for _, item in ipairs(self.items) do
    if item.state == "failed" then
      item.state = "pending"
      item.error = nil
      break
    end
  end
  self:_changed()
  self:dispatch()
end

---@param reason? string
function Queue:pause(reason)
  self.paused = true
  self.paused_reason = reason or "cancelled"
  self:_changed()
end

---@param opts { index: number, kind?: string, text?: string, remove?: boolean, first?: boolean, offset?: number }
function Queue:change(opts)
  local item = self.items[opts.index]
  if not item or item == self.sending then
    return
  end
  if opts.remove then
    table.remove(self.items, opts.index)
  elseif opts.first or opts.offset then
    table.remove(self.items, opts.index)
    table.insert(self.items, opts.first and 1 or math.max(1, math.min(#self.items + 1, opts.index + opts.offset)), item)
  else
    item.kind = opts.kind or item.kind
    item.text = opts.text or item.text
    item.state = "pending"
    item.error = nil
  end
  for index, queued in ipairs(self.items) do
    queued.position = index
  end
  self:_changed()
end

return Queue
