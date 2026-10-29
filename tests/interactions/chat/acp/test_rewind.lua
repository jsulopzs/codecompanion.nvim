local h = require("tests.helpers")

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        mocks_acp = require("tests.mocks.acp")

        -- A chat on session "source" with three turns, whose agent can fork at a message
        function rewind_chat(load_turns)
          local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp" } })
          local conn = mocks_acp.new({ session_id = "source" })
          conn.session_id = "source"
          conn._agent_info.agentCapabilities = { loadSession = true, sessionCapabilities = { fork = {} } }
          conn._turns = { source = {
            { prompt = "first", agent_message_id = "m1" },
            { prompt = "second", agent_message_id = "m2" },
            { prompt = "third\nline", agent_message_id = "m3" },
          } }
          _G.loads = {}
          conn.load_session = function(self, session_id, opts)
            table.insert(_G.loads, { session_id = session_id, fork = opts.fork, at = opts.at })
            local new_id = opts.fork and "forked" or session_id
            self.session_id = new_id
            if opts.fork then self._turns[new_id] = load_turns(opts.at) end
            return true
          end
          chat.acp_connection = conn
          return chat, conn
        end

        function buffer_tail(chat, n)
          return vim.api.nvim_buf_get_lines(chat.bufnr, -n - 1, -1, false)
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["rewind"] = new_set()

T["rewind"]["forks before the chosen turn and puts its prompt back"] = function()
  local result = child.lua([[
    local chat, conn = rewind_chat(function(at) return { { prompt = "first", agent_message_id = "m1" }, { prompt = "second", agent_message_id = at } } end)
    local ok = require("codecompanion.interactions.chat.acp.rewind").to(chat, 3)
    return { ok = ok, loads = _G.loads, session = conn.session_id, tail = buffer_tail(chat, 2) }
  ]])

  h.eq(true, result.ok)
  h.eq({ session_id = "source", fork = true, at = "m2" }, result.loads[1])
  h.eq("forked", result.session)
  h.eq({ "third", "line" }, result.tail)
end

T["rewind"]["restores the chosen files and keeps earlier checkpoints"] = function()
  local result = child.lua([[
    local restored
    package.loaded["codecompanion.interactions.chat.acp.checkpoints"] = {
      restore = function(checkpoint, changes) restored = { tree = checkpoint.tree, changes = changes }; return true end,
    }
    package.loaded["codecompanion.interactions.chat.acp.rewind"] = nil
    local rewind = require("codecompanion.interactions.chat.acp.rewind")

    local chat, conn = rewind_chat(function(at)
      return { { prompt = "first", agent_message_id = "m1" }, { prompt = "second", agent_message_id = at } }
    end)
    for i, turn in ipairs(conn._turns.source) do turn.checkpoint = { root = "/repo", tree = "tree" .. i } end

    local files = { { status = "M", path = "a.lua" } }
    local ok = rewind.to(chat, 3, { files = files })
    local forked = conn:turns(conn.session_id)

    package.loaded["codecompanion.interactions.chat.acp.checkpoints"] = nil
    package.loaded["codecompanion.interactions.chat.acp.rewind"] = nil
    return { ok = ok, restored = restored, carried = { forked[1].checkpoint.tree, forked[2].checkpoint.tree } }
  ]])

  h.eq(true, result.ok)
  h.eq({ tree = "tree3", changes = { { status = "M", path = "a.lua" } } }, result.restored)
  h.eq({ "tree1", "tree2" }, result.carried)
end

T["rewind"]["stays on the original session when the agent ignores the cut"] = function()
  local result = child.lua([[
    local chat, conn = rewind_chat(function() return { { prompt = "first", agent_message_id = "m1" }, { prompt = "second", agent_message_id = "m2" }, { prompt = "third", agent_message_id = "m3" } } end)
    local ok = require("codecompanion.interactions.chat.acp.rewind").to(chat, 2)
    return { ok = ok, loads = _G.loads, session = conn.session_id }
  ]])

  h.eq(false, result.ok)
  h.eq({ session_id = "source" }, { session_id = result.loads[2].session_id })
  h.eq(nil, result.loads[2].fork)
  h.eq("source", result.session)
end

T["rewind"]["rewinding to the first turn starts a new session"] = function()
  local result = child.lua([[
    local chat, conn = rewind_chat(function() return {} end)
    local new_session = false
    conn.ensure_session = function(self) self.session_id = "fresh"; new_session = true; return true end
    local ok = require("codecompanion.interactions.chat.acp.rewind").to(chat, 1)
    return { ok = ok, new_session = new_session, loads = #_G.loads, session = conn.session_id, tail = buffer_tail(chat, 1) }
  ]])

  h.eq(true, result.ok)
  h.eq(true, result.new_session)
  h.eq(0, result.loads)
  h.eq("fresh", result.session)
  h.eq({ "first" }, result.tail)
end

T["rewind"]["refuses while a request is running"] = function()
  local result = child.lua([[
    local chat = rewind_chat(function() return {} end)
    chat.current_request = {}
    return { ok = require("codecompanion.interactions.chat.acp.rewind").to(chat, 2), loads = #_G.loads }
  ]])

  h.eq(false, result.ok)
  h.eq(0, result.loads)
end

return T
