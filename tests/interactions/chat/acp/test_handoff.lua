local h = require("tests.helpers")
local T = MiniTest.new_set()
local child = MiniTest.new_child_neovim()

T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
    end,
    post_once = child.stop,
  },
})

T["Handoff"] = MiniTest.new_set()

T["Handoff"]["keeps the first user message and the newest exchange within the limit"] = function()
  local result = child.lua([[
    local handoff = require("codecompanion.interactions.chat.acp.handoff")
    local chat = {
      adapter = { name = "claude_code" },
      acp_transcript = {
        { role = "user", content = "First question" },
        { role = "assistant", content = string.rep("x", 13000) },
        { role = "user", content = "Newest question" },
        { role = "assistant", content = "Newest answer" },
      },
    }
    local text = handoff.build(chat)
    return { #text, text:find("First question", 1, true) ~= nil, text:find("Newest answer", 1, true) ~= nil, text:find(string.rep("x", 50), 1, true) ~= nil }
  ]])
  h.is_true(result[1] <= 12000)
  h.eq({ true, true, false }, { result[2], result[3], result[4] })
end

T["Handoff"]["includes changed files and opens the other agent with an unsent draft"] = function()
  local result = child.lua([[
    local checkpoints = require("codecompanion.interactions.chat.acp.checkpoints")
    local changes = checkpoints.changes
    checkpoints.changes = function() return { { path = "src/alpha.lua" }, { path = "src/beta.lua" } } end
    local new_buffer = vim.api.nvim_create_buf(false, true)
    local called
    package.loaded["agent_sessions.codecompanion"] = {
      chat = function(opts)
        called = opts.agent
        return { composer = { bufnr = new_buffer, update_height = function() end, focus = function() end } }
      end,
    }
    local handoff = require("codecompanion.interactions.chat.acp.handoff")
    local original = {
      adapter = { name = "claude_code" },
      acp_transcript = { { role = "user", content = "Original question" }, { role = "assistant", content = "Original answer" } },
      acp_connection = { session_id = "one", turns = function() return { { checkpoint = { tree = "before" } } } end },
    }
    local previous = vim.deepcopy(original.acp_transcript)
    local opened = handoff.open(original)
    local draft = table.concat(vim.api.nvim_buf_get_lines(new_buffer, 0, -1, false), "\n")
    checkpoints.changes = changes
    return { called, opened ~= nil, draft, vim.deep_equal(previous, original.acp_transcript) }
  ]])
  h.eq("codex", result[1])
  h.is_true(result[2])
  h.expect_contains("src/alpha.lua", result[3])
  h.expect_contains("src/beta.lua", result[3])
  h.expect_contains("Original answer", result[3])
  h.is_true(result[4])
end

T["Handoff"]["opens Claude from a Codex chat and keeps the source unchanged"] = function()
  local result = child.lua([[
    local handoff = require("codecompanion.interactions.chat.acp.handoff")
    local new_buffer = vim.api.nvim_create_buf(false, true)
    local target
    package.loaded["agent_sessions.codecompanion"] = {
      chat = function(opts)
        target = opts.agent
        return { composer = { bufnr = new_buffer, update_height = function() end, focus = function() end } }
      end,
    }
    local source = { adapter = { name = "codex" }, acp_transcript = { { role = "user", content = "Fix this" } } }
    handoff.open(source)
    local draft = table.concat(vim.api.nvim_buf_get_lines(new_buffer, 0, -1, false), "\n")
    return { target, draft, source.acp_transcript[1].content }
  ]])
  h.eq("claude", result[1])
  h.expect_contains("empezó con Codex", result[2])
  h.eq("Fix this", result[3])
end

return T
