local M = {}

M.get_phpunit_cmd = function()
  return "t"
end

M.get_env = function()
  return {}
end

M.get_root_ignore_files = function()
  return {}
end

M.get_root_files = function()
  return { ".gitignore", ".arcconfig" }
end

M.get_filter_dirs = function()
  return { ".git", ".hg", "node_modules" }
end

return M
