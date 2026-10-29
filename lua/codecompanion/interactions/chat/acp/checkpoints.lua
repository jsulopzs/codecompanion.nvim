--[[
File checkpoints for ACP chats.

No agent restores files over ACP, so the client snapshots the working tree itself: before each prompt it writes the
tree's current state into the repository's object store, and a rewind can put the files back the way they were.
It sees every change on disk, whichever agent made it and however (an edit tool or a shell command).

A snapshot goes through a temporary index seeded from the real one, so it never touches the user's index, branch or
stash. It only works inside a git repository, and files git ignores aren't in it.
--]]

local log = require("codecompanion.utils.log")

local M = {}

---@class CodeCompanion.ACP.Checkpoint
---@field root string The repository's top-level directory
---@field tree string The tree object holding the working tree as it was

---@class CodeCompanion.ACP.CheckpointChange
---@field status "A"|"M"|"D" Added, modified or deleted since the checkpoint
---@field path string Relative to the repository root

---Run git, optionally against a temporary index
---@param args string[]
---@param opts { cwd: string, index?: string }
---@return boolean ok, string stdout
local function git(args, opts)
  local result = vim
    .system(vim.list_extend({ "git" }, args), {
      cwd = opts.cwd,
      env = opts.index and { GIT_INDEX_FILE = opts.index } or nil,
      text = true,
    })
    :wait()
  return result.code == 0, vim.trim(result.stdout or "")
end

---Run fn with a temporary index seeded from the repository's own, so git only rehashes files that changed
---@param root string
---@param fn fun(index: string): any
---@return any
local function with_temp_index(root, fn)
  local index = vim.fn.tempname()
  local ok, real = git({ "rev-parse", "--path-format=absolute", "--git-path", "index" }, { cwd = root })
  if ok and vim.uv.fs_stat(real) then
    vim.uv.fs_copyfile(real, index)
  end
  local result = fn(index)
  os.remove(index)
  return result
end

---The tree object for the working tree as it is now
---@param root string
---@return string|nil
local function write_tree(root)
  return with_temp_index(root, function(index)
    if not git({ "add", "--all", "." }, { cwd = root, index = index }) then
      return nil
    end
    local ok, tree = git({ "write-tree" }, { cwd = root, index = index })
    return ok and tree or nil
  end)
end

---Snapshot the working tree of the repository that holds cwd
---@param cwd string
---@return CodeCompanion.ACP.Checkpoint|nil nil outside a git repository or when git fails
function M.snapshot(cwd)
  local ok, root = git({ "rev-parse", "--show-toplevel" }, { cwd = cwd })
  if not ok or root == "" then
    return nil
  end
  local tree = write_tree(root)
  if not tree then
    log:debug("[acp::checkpoints] Could not snapshot %s", root)
    return nil
  end
  return { root = root, tree = tree }
end

---What changed on disk since a checkpoint
---@param checkpoint CodeCompanion.ACP.Checkpoint
---@return CodeCompanion.ACP.CheckpointChange[]|nil nil when the working tree can't be read
function M.changes(checkpoint)
  local now = write_tree(checkpoint.root)
  if not now then
    return nil
  end
  if now == checkpoint.tree then
    return {}
  end
  local ok, out = git(
    { "diff-tree", "-r", "--no-renames", "--name-status", checkpoint.tree, now },
    { cwd = checkpoint.root }
  )
  if not ok then
    return nil
  end
  local changes = {}
  for line in out:gmatch("[^\n]+") do
    local status, path = line:match("^(%a)%s+(.+)$")
    if status then
      -- A type change (file to symlink) restores like a modification
      table.insert(changes, { status = status == "T" and "M" or status, path = path })
    end
  end
  return changes
end

---Put the files back the way they were at a checkpoint: changed and deleted files get their old content back, and
---files created since are removed
---@param checkpoint CodeCompanion.ACP.Checkpoint
---@param changes CodeCompanion.ACP.CheckpointChange[]
---@return boolean ok
function M.restore(checkpoint, changes)
  local restore, created = {}, {}
  for _, change in ipairs(changes) do
    table.insert(change.status == "A" and created or restore, change.path)
  end

  local ok = true
  if #restore > 0 then
    ok = with_temp_index(checkpoint.root, function(index)
      return git({ "read-tree", checkpoint.tree }, { cwd = checkpoint.root, index = index })
        and git(
          vim.list_extend({ "checkout-index", "--force", "--" }, restore),
          { cwd = checkpoint.root, index = index }
        )
    end)
  end
  for _, path in ipairs(created) do
    local removed = os.remove(vim.fs.joinpath(checkpoint.root, path))
    ok = ok and removed ~= nil
  end

  -- Buffers showing the restored files pick up their old content
  vim.cmd("silent! checktime")
  return ok and true or false
end

return M
