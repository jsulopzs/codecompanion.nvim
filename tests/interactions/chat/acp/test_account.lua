local h = require("tests.helpers")
local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        account = require("codecompanion.interactions.chat.acp.account")
        local signal_dir = vim.fn.tempname()
        account._signal_dir = function() return signal_dir end

        calls = {}
        function make_chat(opts)
          local chat = {
            title = opts.title,
            current_request = opts.busy and {} or nil,
            rate_limit = opts.blocked and { status = "rejected", resetsAt = os.time() + 3600 } or nil,
            acp_connection = {
              adapter = { name = opts.agent or "claude_code" },
              session_id = "session-" .. opts.title,
              _state = { handle = {} },
              restart_after_login = function(_, restart)
                table.insert(calls, { "restart", opts.title, restart and restart.quiet })
                return true
              end,
            },
            queue = {
              paused = opts.blocked,
              paused_reason = opts.blocked and "error" or nil,
              resume = function() table.insert(calls, { "resume", opts.title }) end,
            },
          }
          return chat
        end

        function use_chats(list)
          require("codecompanion.interactions.chat").buf_get_chat = function()
            return vim.tbl_map(function(chat) return { chat = chat } end, list)
          end
        end
      ]])
    end,
    post_case = child.stop,
  },
})

T["Account"] = MiniTest.new_set()

T["Account"]["reloads the BLOCKED chats of the same agent and retries their failed prompt"] = function()
  local result = child.lua([[
    local origin = make_chat({ title = "origin" })
    local blocked = make_chat({ title = "blocked", blocked = true })
    local healthy = make_chat({ title = "healthy" })
    local other_agent = make_chat({ title = "codex", agent = "codex", blocked = true })
    use_chats({ origin, blocked, healthy, other_agent })
    account.announce(origin)
    return {
      calls = calls,
      cleared = blocked.rate_limit == nil,
      healthy_stale = healthy._acp_account_stale,
      other_untouched = other_agent._acp_account_stale == nil,
      origin_untouched = origin._acp_account_stale == nil,
    }
  ]])
  h.eq({ { "restart", "blocked", true }, { "resume", "blocked" } }, result.calls)
  h.is_true(result.cleared)
  h.is_true(result.healthy_stale)
  h.is_true(result.other_untouched)
  h.is_true(result.origin_untouched)
end

T["Account"]["DOES NOT restart a blocked chat while its turn is IN PROGRESS"] = function()
  local result = child.lua([[
    local origin = make_chat({ title = "origin" })
    local busy = make_chat({ title = "busy", blocked = true, busy = true })
    use_chats({ origin, busy })
    account.announce(origin)
    return { calls = calls, stale = busy._acp_account_stale }
  ]])
  h.eq({}, result.calls)
  h.is_true(result.stale)
end

T["Account"]["reloads blocked chats when ANOTHER Neovim logs in"] = function()
  local result = child.lua([[
    local blocked = make_chat({ title = "blocked", blocked = true })
    use_chats({ blocked })
    account.watch("claude_code")
    account.check()
    local before = vim.deepcopy(calls)

    local path = vim.fs.joinpath(account._signal_dir(), "claude_code.json")
    vim.fn.writefile({ vim.json.encode({ id = "other-neovim" }) }, path)
    account.check()
    return { before = before, after = calls }
  ]])
  h.eq({}, result.before)
  h.eq({ { "restart", "blocked", true }, { "resume", "blocked" } }, result.after)
end

T["Account"]["reloads a stale chat before sending its next prompt"] = function()
  local result = child.lua([[
    local chat = make_chat({ title = "healthy" })
    chat._acp_account_stale = true
    local handler = require("codecompanion.interactions.chat.acp.handler").new(chat)
    handler.ensure_connection = function()
      table.insert(calls, { "connect" })
      return false
    end
    chat.done = function() end
    handler:submit({})
    return { calls = calls, cleared = chat._acp_account_stale == nil }
  ]])
  h.eq({ { "restart", "healthy", true }, { "connect" } }, result.calls)
  h.is_true(result.cleared)
end

return T
