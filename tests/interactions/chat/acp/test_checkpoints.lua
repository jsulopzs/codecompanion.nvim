local h = require("tests.helpers")

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        checkpoints = require("codecompanion.interactions.chat.acp.checkpoints")

        -- A repository with a committed file, a staged edit and an untracked file
        function make_repo()
          local root = vim.fn.resolve(vim.fn.tempname())
          vim.fn.mkdir(root, "p")
          local function sh(cmd) return vim.fn.system("cd " .. vim.fn.shellescape(root) .. " && " .. cmd) end
          sh("git init -q && git config user.email t@t && git config user.name t")
          vim.fn.writefile({ "one" }, root .. "/kept.txt")
          vim.fn.writefile({ "gone" }, root .. "/deleted.txt")
          sh("git add . && git commit -qm init")
          vim.fn.writefile({ "staged" }, root .. "/kept.txt")
          sh("git add kept.txt")
          vim.fn.writefile({ "draft" }, root .. "/notes.txt")
          return root, sh
        end
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["checkpoints"] = new_set()

T["checkpoints"]["restores changed, deleted and created files without touching the index"] = function()
  local result = child.lua([[
    local root, sh = make_repo()
    local status_before = sh("git status --porcelain")
    local checkpoint = checkpoints.snapshot(root)

    -- What an agent might do afterwards
    vim.fn.writefile({ "agent edit" }, root .. "/kept.txt")
    vim.fn.writefile({ "agent edit" }, root .. "/notes.txt")
    os.remove(root .. "/deleted.txt")
    vim.fn.writefile({ "new" }, root .. "/created.txt")

    local changes = checkpoints.changes(checkpoint)
    table.sort(changes, function(a, b) return a.path < b.path end)
    local ok = checkpoints.restore(checkpoint, changes)

    return {
      changes = changes,
      ok = ok,
      kept = vim.fn.readfile(root .. "/kept.txt")[1],
      notes = vim.fn.readfile(root .. "/notes.txt")[1],
      deleted = vim.fn.filereadable(root .. "/deleted.txt"),
      created = vim.fn.filereadable(root .. "/created.txt"),
      status_same = sh("git status --porcelain") == status_before,
      after = checkpoints.changes(checkpoint),
    }
  ]])

  h.eq({
    { status = "A", path = "created.txt" },
    { status = "D", path = "deleted.txt" },
    { status = "M", path = "kept.txt" },
    { status = "M", path = "notes.txt" },
  }, result.changes)
  h.eq(true, result.ok)
  h.eq("staged", result.kept)
  h.eq("draft", result.notes)
  h.eq(1, result.deleted)
  h.eq(0, result.created)
  h.eq(true, result.status_same)
  h.eq({}, result.after)
end

T["checkpoints"]["reports no changes when nothing moved"] = function()
  local result = child.lua([[
    local root = make_repo()
    return checkpoints.changes(checkpoints.snapshot(root))
  ]])
  h.eq({}, result)
end

T["checkpoints"]["does nothing outside a git repository"] = function()
  local result = child.lua([[
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return checkpoints.snapshot(dir) == nil
  ]])
  h.eq(true, result)
end

return T
