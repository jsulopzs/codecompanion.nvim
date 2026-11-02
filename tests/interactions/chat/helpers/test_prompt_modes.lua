local h = require("tests.helpers")

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        chat = h.setup_chat_buffer()
        vim.api.nvim_set_current_buf(chat.bufnr)

        -- Pretend the user is typing, and record whether the prompt leaves insert mode
        _G.left_insert = false
        local get_mode = vim.api.nvim_get_mode
        vim.api.nvim_get_mode = function() return { mode = "i", blocking = false } end
        local cmd = vim.cmd
        vim.cmd = setmetatable({}, {
          __call = function(_, c) if c == "stopinsert" then _G.left_insert = true else return cmd(c) end end,
          __index = cmd,
        })

        function approve()
          require("codecompanion.interactions.chat.helpers.approval_prompt").request(chat, {
            id = 1,
            title = "Run a command",
            choices = { { keymap = "g2", label = "Accept", callback = function() end } },
          })
        end
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["prompts"] = new_set()

T["prompts"]["an approval takes the chat out of insert mode so its keys answer"] = function()
  child.lua([[approve()]])
  h.eq(true, child.lua_get("_G.left_insert"))
end

T["prompts"]["a question takes the chat out of insert mode so its keys answer"] = function()
  child.lua([[
    require("codecompanion.interactions.chat.helpers.question_prompt").ask(chat, {
      question = { question = "Colour?", options = { { label = "Red" }, { label = "Blue" } } },
      index = 1,
      total = 1,
      callback = function() end,
    })
  ]])
  h.eq(true, child.lua_get("_G.left_insert"))
end

T["prompts"]["typing in another buffer is left alone"] = function()
  child.lua([[
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
    approve()
  ]])
  h.eq(false, child.lua_get("_G.left_insert"))
end

T["composer"] = new_set()

local acp_chat = [[
  local chat = h.setup_chat_buffer({}, { name = "test_acp", config = { name = "test_acp", type = "acp", formatted_name = "Test ACP", handlers = { form_messages = function(_, messages) return messages end } } })
  local function press(bufnr, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if map.lhs == lhs then
        map.callback()
        return true
      end
    end
    return false
  end
  local function hint()
    local marks = vim.api.nvim_buf_get_extmarks(chat.composer.bufnr, -1, 0, -1, { details = true })
    return table.concat(vim.tbl_map(function(segment) return segment[1] end, marks[#marks][4].virt_lines[1]))
  end
]]

T["composer"]["answers an approval from the composer and clears its keys in both buffers"] = function()
  local result = child.lua(acp_chat .. [[
    local chosen
    require("codecompanion.interactions.chat.helpers.approval_prompt").request(chat, {
      id = 1,
      title = "Run a command",
      choices = { { keymap = "g2", label = "Accept", callback = function() chosen = "Accept" end } },
    })
    local waiting = hint()
    local pressed = press(chat.composer.bufnr, "g2")
    return {
      pressed = pressed,
      chosen = chosen,
      waiting = waiting,
      after = hint(),
      left_in_composer = #vim.tbl_filter(function(m) return m.lhs == "g2" end, vim.api.nvim_buf_get_keymap(chat.composer.bufnr, "n")),
      left_in_chat = #vim.tbl_filter(function(m) return m.lhs == "g2" end, vim.api.nvim_buf_get_keymap(chat.bufnr, "n")),
    }
  ]])
  h.is_true(result.pressed)
  h.eq("Accept", result.chosen)
  h.expect_contains("waiting for your answer · g2", result.waiting)
  h.eq(nil, result.after:find("waiting for your answer", 1, true))
  h.eq(0, result.left_in_composer)
  h.eq(0, result.left_in_chat)
end

T["composer"]["answers a question from the composer and restores the composer's own keys"] = function()
  local result = child.lua(acp_chat .. [[
    vim.keymap.set("n", "gs", function() _G.composer_gs = true end, { buffer = chat.composer.bufnr })
    local answer
    require("codecompanion.interactions.chat.helpers.question_prompt").ask(chat, {
      question = { question = "Colour?", options = { { label = "Red" }, { label = "Blue" } } },
      index = 1,
      total = 1,
      callback = function(a) answer = a end,
    })
    local waiting = hint()
    press(chat.composer.bufnr, "g2")
    press(chat.composer.bufnr, "gs")
    return {
      answer = answer,
      waiting = waiting,
      restored = _G.composer_gs == true,
      left_in_chat = #vim.tbl_filter(function(m) return m.lhs == "g2" end, vim.api.nvim_buf_get_keymap(chat.bufnr, "n")),
    }
  ]])
  h.eq("Blue", result.answer)
  h.expect_contains("waiting for your answer · gs g1 g2 gc", result.waiting)
  h.is_true(result.restored)
  h.eq(0, result.left_in_chat)
end

return T
