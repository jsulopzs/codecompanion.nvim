local h = require("tests.helpers")
local T = MiniTest.new_set()
local child = MiniTest.new_child_neovim()

T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
    end,
    pre_case = function()
      child.lua([[
        local config = require("codecompanion.config")
        config.interactions.chat.queue.save = false
        package.loaded["codecompanion.interactions.chat.queue.view"] = { render = function() end }
        function make_queue()
          local chat = { bufnr = vim.api.nvim_create_buf(false, true), acp_connection = {}, sent = {}, opts = {} }
          function chat:send_text(text)
            table.insert(self.sent, text)
            self.current_request = {}
            return true
          end
          local queue = require("codecompanion.interactions.chat.queue").new(chat)
          chat.queue = queue
          return queue, chat
        end
      ]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})

T["Queue"] = MiniTest.new_set()

T["Queue"]["sends pending prompts in FIFO order after end_turn"] = function()
  local result = child.lua([[
    local queue, chat = make_queue()
    chat.current_request = {}
    queue:add({ text = "first" })
    queue:add({ text = "second" })
    queue:add({ text = "third" })
    chat.current_request = nil
    queue:dispatch()
    local positions
    for _ = 1, 3 do
      chat.current_request = nil
      queue:turn_finished({ reason = "end_turn" })
      if not positions then
        positions = { queue.items[1].position, queue.items[2].position }
      end
      vim.wait(20)
    end
    return { sent = chat.sent, remaining = #queue.items, positions = positions }
  ]])
  h.eq({ "first", "second", "third" }, result.sent)
  h.eq(0, result.remaining)
  h.eq({ 1, 2 }, result.positions)
end

T["Queue"]["does not send while a prompt or autonomous turn is active"] = function()
  local result = child.lua([[
    local queue, chat = make_queue()
    chat.current_request = {}
    queue:add({ text = "later" })
    chat.current_request = nil
    chat.acp_connection._autonomous_turn = {}
    queue:dispatch()
    return { sent = #chat.sent, state = queue.items[1].state }
  ]])
  h.eq(0, result.sent)
  h.eq("pending", result.state)
end

T["Queue"]["pauses after stop and error"] = function()
  local result = child.lua([[
    local queue, chat = make_queue()
    chat.current_request = {}
    queue:add({ text = "later" })
    queue:pause()
    chat.current_request = nil
    queue:turn_finished({ reason = "canceled" })
    queue:dispatch()
    local stopped = #chat.sent
    queue:resume()
    chat.current_request = nil
    queue:turn_finished({ reason = "refusal" })
    return { stopped = stopped, sent = #chat.sent, paused = queue.paused }
  ]])
  h.eq(0, result.stopped)
  h.eq(1, result.sent)
  h.is_true(result.paused)
end

T["Queue"]["keeps a prompt rejected before acceptance first until resumed"] = function()
  local result = child.lua([[
    local queue, chat = make_queue()
    chat.current_request = {}
    queue:add({ text = "first" })
    queue:add({ text = "second" })
    chat.current_request = nil
    queue:dispatch()
    chat.current_request = nil
    queue:turn_finished({ reason = "error", error = "Connection lost" })
    local failed = queue.items[1].state
    queue:resume()
    return { failed = failed, sent = chat.sent, first = queue.items[1].text }
  ]])
  h.eq("failed", result.failed)
  h.eq({ "first", "first" }, result.sent)
  h.eq("first", result.first)
end

T["Queue"]["does not resend a prompt accepted before cancellation"] = function()
  local result = child.lua([[
    local queue, chat = make_queue()
    chat.current_request = {}
    queue:add({ text = "first" })
    queue:add({ text = "second" })
    chat.current_request = nil
    queue:dispatch()
    queue:mark_accepted()
    chat.current_request = nil
    queue:turn_finished({ reason = "canceled" })
    local paused = queue.paused
    queue:resume()
    return { sent = chat.sent, paused = paused, remaining = #queue.items, first = queue.items[1].text }
  ]])
  h.eq({ "first", "second" }, result.sent)
  h.is_true(result.paused)
  h.eq(1, result.remaining)
  h.eq("second", result.first)
end

T["Queue"]["rejects rewind and resume while preserving the queue"] = function()
  local result = child.lua([[
    local queue = make_queue()
    local rewind = queue:add({ text = "/rewind" })
    local resume = queue:add({ text = "/resume old-session" })
    return { rewind = rewind, resume = resume, count = #queue.items }
  ]])
  h.eq(nil, result.rewind)
  h.eq(nil, result.resume)
  h.eq(0, result.count)
end

T["Queue"]["expands editor context when a prompt leaves the queue"] = function()
  local result = child.lua([[
    local queue, chat = make_queue()
    chat.current_request = {}
    function chat:send_text(text)
      self.sent = { require("codecompanion.interactions.chat.queue.dispatcher").expand({ chat = self, text = text }) }
      self.current_request = {}
      return true
    end
    queue:add({ text = "Check #buffer" })
    local stored = queue.items[1].text
    chat.current_request = nil
    queue:dispatch()
    return { stored = stored, sent = chat.sent[1] }
  ]])
  h.eq("Check #buffer", result.stored)
  h.eq("Check #{buffer}", result.sent)
end

T["Queue"]["keeps parked ideas until promoted"] = function()
  local result = child.lua([[
    local queue, chat = make_queue()
    queue:add({ text = "idea", kind = "parked" })
    local before = #chat.sent
    queue:change({ index = 1, kind = "pending" })
    queue:dispatch()
    return { before = before, after = chat.sent[1] }
  ]])
  h.eq(0, result.before)
  h.eq("idea", result.after)
end

T["Queue"]["restores pending and parked items paused after reopening"] = function()
  local result = child.lua([[
    local config = require("codecompanion.config")
    local store = require("codecompanion.interactions.chat.queue.store")
    config.interactions.chat.queue.save = true
    local session_id = "test-queue-" .. tostring(vim.uv.hrtime())
    local queue, chat = make_queue()
    chat.current_request = {}
    queue:attach(session_id)
    queue:add({ text = "next", kind = "pending" })
    queue:add({ text = "idea", kind = "parked" })
    queue:pause()
    local restored = require("codecompanion.interactions.chat.queue").new(chat)
    restored:attach(session_id)
    local path = vim.fs.joinpath(vim.fn.stdpath("state"), "codecompanion", "queue", session_id .. ".json")
    local data = store.load({ session_id = session_id })
    require("codecompanion.utils.files").delete(path)
    return { paused = restored.paused, first = restored.items[1].text, second = restored.items[2].kind, saved = data.session_id }
  ]])
  h.is_true(result.paused)
  h.eq("next", result.first)
  h.eq("parked", result.second)
  h.is_true(result.saved:find("test-queue-", 1, true) == 1)
end

T["Queue"]["pauses a saved active queue when resuming a session"] = function()
  local result = child.lua([[
    local config = require("codecompanion.config")
    config.interactions.chat.queue.save = true
    local session_id = "test-queue-" .. tostring(vim.uv.hrtime())
    local queue, chat = make_queue()
    chat.current_request = {}
    queue:attach(session_id)
    queue:add({ text = "next" })
    local reopened_chat = { bufnr = vim.api.nvim_create_buf(false, true), acp_connection = {}, acp_session_id = session_id, sent = {} }
    function reopened_chat:send_text(text) table.insert(self.sent, text); return true end
    local restored = require("codecompanion.interactions.chat.queue").new(reopened_chat)
    restored:attach(session_id)
    require("codecompanion.utils.files").delete(vim.fs.joinpath(vim.fn.stdpath("state"), "codecompanion", "queue", session_id .. ".json"))
    return { paused = restored.paused, reason = restored.paused_reason, sent = #reopened_chat.sent }
  ]])
  h.is_true(result.paused)
  h.eq("resumed", result.reason)
  h.eq(0, result.sent)
end

T["Queue"]["renders queued and parked items below the history"] = function()
  local result = child.lua([[
    package.loaded["codecompanion.interactions.chat.queue.view"] = nil
    local queue, chat = make_queue()
    queue.paused = true
    queue:add({ text = "next", kind = "pending" })
    queue:add({ text = "idea", kind = "parked" })
    local marks = vim.api.nvim_buf_get_extmarks(chat.bufnr, -1, 0, -1, { details = true })
    local virtual = marks[1] and marks[1][4].virt_lines or {}
    return { first = virtual[1] and virtual[1][1][1], second = virtual[2] and virtual[2][1][1] }
  ]])
  h.is_true(result.first:find("Queued 1", 1, true) ~= nil)
  h.is_true(result.second:find("Parked 2", 1, true) ~= nil)
end

return T
