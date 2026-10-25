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
        elicitation = require('codecompanion.interactions.chat.acp.elicitation')

        -- The chat buffer binds its own keys (e.g. gc, gs), so only match the
        -- question prompt's mappings via their desc prefix
        function _G.wait_for_keymap(lhs, previous)
          local found
          vim.wait(2000, function()
            for _, map in ipairs(vim.api.nvim_buf_get_keymap(chat.bufnr, 'n')) do
              if map.lhs == lhs
                and map.callback
                and map.callback ~= previous
                and map.desc
                and map.desc:find('CodeCompanion question', 1, true) == 1
              then
                found = map.callback
                return true
              end
            end
            return false
          end, 20)
          assert(found, 'Expected question keymap `' .. lhs .. '` to be set on the chat buffer')
          return found
        end

        function _G.press(lhs, previous)
          local callback = _G.wait_for_keymap(lhs, previous)
          callback()
          return callback
        end

        function _G.ask(message, schema)
          _G.response = nil
          elicitation.ask(chat, {
            message = message,
            requested_schema = schema,
            respond = function(response)
              _G.response = vim.json.encode(response)
            end,
          })
        end

        function _G.wait_for_response()
          vim.wait(2000, function()
            return _G.response ~= nil
          end, 20)
          return _G.response
        end

        function _G.buffer_text()
          return table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), '\n')
        end

        cache_schema = {
          type = "object",
          properties = {
            question_0 = {
              type = "string",
              title = "Cache",
              oneOf = {
                { const = "redis", title = "Redis" },
                { const = "memcached", title = "Memcached", description = "Simpler" },
              },
            },
            question_0_custom = { type = "string", title = "Other" },
          },
        }
      ]])
    end,
    post_case = function()
      child.lua([[
        h.teardown_chat_buffer()
      ]])
    end,
    post_once = child.stop,
  },
})

T["Elicitation"] = new_set()

T["Elicitation"]["answers a select question with the option's value"] = function()
  local response = child.lua([[
    _G.ask("Which cache should I use?", cache_schema)
    _G.press('g2')
    return _G.wait_for_response()
  ]])

  h.eq({ action = "accept", content = { question_0 = "memcached" } }, vim.json.decode(response))

  local buffer = child.lua_get([[_G.buffer_text()]])
  h.expect_contains("Question 1 of 1", buffer)
  h.expect_contains("Which cache should I use?", buffer)
end

T["Elicitation"]["sends a typed answer to the matching _custom property"] = function()
  local response = child.lua([[
    vim.ui.input = function(opts, callback)
      callback('Valkey')
    end

    _G.ask("Which cache should I use?", cache_schema)
    _G.press('gc')
    return _G.wait_for_response()
  ]])

  h.eq({ action = "accept", content = { question_0_custom = "Valkey" } }, vim.json.decode(response))
end

T["Elicitation"]["answers a multi select question with a list of values"] = function()
  local response = child.lua([[
    _G.ask("Please answer the following questions.", {
      type = "object",
      properties = {
        question_0 = {
          type = "array",
          title = "Modules",
          description = "Which modules should own this logic?",
          items = {
            anyOf = {
              { const = "queue", title = "Queue" },
              { const = "orchestrator", title = "Orchestrator" },
              { const = "runner", title = "Runner, sync" },
            },
          },
        },
      },
    })
    _G.press('g1')
    _G.press('g2')
    _G.press('g1')
    return _G.wait_for_response()
  ]])

  h.eq({ action = "accept", content = { question_0 = { "queue", "runner" } } }, vim.json.decode(response))
end

T["Elicitation"]["answers a boolean question with false"] = function()
  local response = child.lua([[
    _G.ask("Deploy now?", {
      type = "object",
      properties = { deploy = { type = "boolean", title = "Deploy" } },
    })
    _G.press('g2')
    return _G.wait_for_response()
  ]])

  h.eq({ action = "accept", content = { deploy = false } }, vim.json.decode(response))
end

T["Elicitation"]["accepts with an empty object when an OPTIONAL question is skipped"] = function()
  local response = child.lua([[
    _G.ask("Anything else?", {
      type = "object",
      properties = { notes = { type = "string", title = "Notes" } },
    })
    _G.press('gs')
    return _G.wait_for_response()
  ]])

  h.eq("accept", vim.json.decode(response).action)
  h.expect_contains('"content":{}', response)
end

T["Elicitation"]["declines when a REQUIRED question is skipped"] = function()
  local response = child.lua([[
    _G.ask("Which branch?", {
      type = "object",
      properties = { branch = { type = "string", title = "Branch" } },
      required = { "branch" },
    })
    _G.press('gs')
    return _G.wait_for_response()
  ]])

  h.eq({ action = "decline" }, vim.json.decode(response))
end

return T
