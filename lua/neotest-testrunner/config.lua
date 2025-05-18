local M = {}

M.get_cmd = function()
  return "t"
end

M.get_env = function()
  return {}
end

M.get_root_files = function()
  return { ".arcconfig" }
end

return M
