local question_prompt = require("codecompanion.interactions.chat.helpers.question_prompt")

local SUPPORTED_TYPES = { string = true, number = true, integer = true, boolean = true, array = true }

---@class CodeCompanion.Chat.ACPElicitation
local M = {}

---The options a property offers, each carrying the value the agent expects back
---@param property table
---@return { label: string, description?: string, value: any }[]
local function get_options(property)
  if property.type == "boolean" then
    return { { label = "Yes", value = true }, { label = "No", value = false } }
  end

  local choices = property.oneOf or property.enum
  if property.type == "array" then
    choices = property.items and (property.items.anyOf or property.items.enum)
  end

  return vim.tbl_map(function(choice)
    if type(choice) == "string" then
      return { label = choice, value = choice }
    end
    return { label = choice.title or choice.const, description = choice.description, value = choice.const }
  end, choices or {})
end

---@param opts { options: table[], label: string }
---@return table|nil
local function find_option(opts)
  return vim.iter(opts.options):find(function(option)
    return option.label == opts.label
  end)
end

---Turn the requested schema into the questions to ask, one per property
---@param request { message: string, requested_schema: table }
---@return table[]
local function build_questions(request)
  local properties = request.requested_schema.properties or {}
  local keys = vim.tbl_keys(properties)
  table.sort(keys)

  local questions = {}
  local by_key = {}
  for _, key in ipairs(keys) do
    local property = properties[key]
    local select_key = key:match("^(.+)_custom$")
    local select_question = select_key and by_key[select_key]

    -- claude-agent-acp follows each select property with an optional `<key>_custom` property for a typed answer
    if select_question and #select_question.options > 0 and #get_options(property) == 0 then
      select_question.custom_key = key
    elseif SUPPORTED_TYPES[property.type] then
      local options = get_options(property)
      local entry = { key = key, property = property, options = options }
      entry.question = { header = property.title or key, multiSelect = property.type == "array", options = options }
      by_key[key] = entry
      table.insert(questions, entry)
    end
  end

  for _, entry in ipairs(questions) do
    local property = entry.property
    entry.question.question = property.description or (#questions == 1 and request.message) or entry.question.header
  end

  return questions
end

---Store an answer in the form content as the value its property expects
---@param content table
---@param opts { entry: table, answer: string, selected?: string[] }
local function record_answer(content, opts)
  local entry = opts.entry

  if entry.property.type == "array" then
    content[entry.key] = vim.tbl_map(function(label)
      return find_option({ options = entry.options, label = label }).value
    end, opts.selected or {})
    return
  end

  local option = find_option({ options = entry.options, label = opts.answer })
  if option then
    content[entry.key] = option.value
  elseif entry.custom_key then
    content[entry.custom_key] = opts.answer
  elseif entry.property.type == "number" or entry.property.type == "integer" then
    content[entry.key] = tonumber(opts.answer)
  else
    content[entry.key] = opts.answer
  end
end

---@param content table
---@param schema table
---@return boolean
local function has_required_answers(content, schema)
  return vim.iter(schema.required or {}):all(function(key)
    return content[key] ~= nil
  end)
end

---Ask each question of a form elicitation in the chat buffer and respond with the answers
---@param chat CodeCompanion.Chat
---@param request { message: string, requested_schema: table, respond: fun(response: table|nil, cancelled?: boolean) }
---@return nil
function M.ask(chat, request)
  local questions = build_questions(request)
  local content = vim.empty_dict()
  local index = 0

  local function next_question()
    index = index + 1
    if index > #questions then
      if not has_required_answers(content, request.requested_schema) then
        return request.respond({ action = "decline" })
      end
      return request.respond({ action = "accept", content = content })
    end

    local entry = questions[index]
    question_prompt.ask(chat, {
      question = entry.question,
      index = index,
      total = #questions,
      callback = function(answer, selection)
        if answer then
          record_answer(content, { entry = entry, answer = answer, selected = selection and selection.selected })
        end
        next_question()
      end,
    })
  end

  next_question()
end

return M
