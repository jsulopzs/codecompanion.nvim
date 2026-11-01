local config = require("codecompanion.config")

local Tasks = {}
Tasks.__index = Tasks

local finished = { completed = true, failed = true, stopped = true }

---@param chat CodeCompanion.Chat
function Tasks.new(chat)
  return setmetatable({ chat = chat, session_id = nil, items = {}, order = {}, schedules = {} }, Tasks)
end

---@param session_id string|nil
---@param opts? { reset?: boolean }
function Tasks:attach(session_id, opts)
  if self.session_id == session_id and not (opts and opts.reset) then
    return
  end
  self.session_id = session_id
  self.items, self.order, self.schedules = {}, {}, {}
  self:_changed()
end

function Tasks:_changed()
  if self.chat.queue then
    require("codecompanion.interactions.chat.queue.view").render(self.chat.queue)
  end
  if self.chat.composer then
    self.chat.composer:update_status()
  end
end

---@param update table
function Tasks:update(update)
  if not config.interactions.chat.tasks.enabled then
    return
  end
  local kind = update.sessionUpdate
  if kind == "session_schedules_update" then
    if not self.chat.acp_connection or not self.chat.acp_connection:task_detail_supported("schedules") then
      return
    end
    self.schedules = update.schedules or {}
  elseif kind == "async_task_spawned" and update.taskType ~= "turn" and update.asyncTaskId then
    if
      update.taskType == "monitor"
      and (not self.chat.acp_connection or not self.chat.acp_connection:task_detail_supported("monitors"))
    then
      return
    end
    local task = self.items[update.asyncTaskId]
    if not task then
      task = { asyncTaskId = update.asyncTaskId, state = "running" }
      self.items[update.asyncTaskId] = task
      table.insert(self.order, update.asyncTaskId)
    end
    for key, value in pairs(update) do
      task[key] = value
    end
  elseif (kind == "async_task_progress" or kind == "async_task_state_update") and self.items[update.asyncTaskId] then
    local task = self.items[update.asyncTaskId]
    local was_finished = finished[task.state]
    for key, value in pairs(update) do
      task[key] = value
    end
    if not was_finished and (task.state == "completed" or task.state == "failed") and self.chat.ui and not self.chat.ui:is_visible() then
      vim.notify(task.summary or (task.name or task.asyncTaskId) .. " · " .. task.state, vim.log.levels.INFO, {
        title = self.chat.title or self.chat.adapter.formatted_name,
      })
    end
  else
    return
  end
  self:_changed()
end

function Tasks:clear_finished()
  for index = #self.order, 1, -1 do
    local id = self.order[index]
    if finished[self.items[id].state] then
      self.items[id] = nil
      table.remove(self.order, index)
    end
  end
  self:_changed()
end

function Tasks:counts()
  local active = 0
  for _, id in ipairs(self.order) do
    if not finished[self.items[id].state] then
      active = active + 1
    end
  end
  return active, #self.schedules
end

return Tasks
