local files = require("codecompanion.utils.files")
local log = require("codecompanion.utils.log")

local M = {}

local function path_for(session_id)
  local safe_id = session_id:gsub("[^%w%-_]", "_")
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codecompanion", "queue", safe_id .. ".json")
end

---@param opts { session_id: string }
---@return table|nil
function M.load(opts)
  local path = path_for(opts.session_id)
  if not files.exists(path) then
    return nil
  end
  local ok, value = pcall(function()
    return vim.json.decode(files.read(path))
  end)
  if not ok or type(value) ~= "table" then
    log:error("Could not load chat queue: %s", path)
    return nil
  end
  return value
end

---@param opts { session_id: string, value: table }
---@return boolean|nil
function M.save(opts)
  local path = path_for(opts.session_id)
  local ok, error_message = pcall(files.write_to_path, path, vim.json.encode(opts.value))
  if not ok then
    log:error("Could not save chat queue: %s", error_message)
    return nil
  end
  return true
end

return M
