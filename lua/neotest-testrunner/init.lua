local lib = require("neotest.lib")
local logger = require("neotest.logging")
local utils = require("neotest-testrunner.utils")
local config = require("neotest-testrunner.config")

---@class neotest.Adapter
---@field name string
local NeotestAdapter = { name = "neotest-testrunner" }

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
function NeotestAdapter.root(dir)
  for _, root_file in ipairs(config.get_root_files()) do
    local result = lib.files.match_root_pattern(root_file)(dir)
    if result then
      return result
    end
  end
end

---@async
---@param file_path string
---@return boolean
function NeotestAdapter.is_test_file(file_path)
  -- TODO: We might want to support other files in the future
  return vim.endswith(file_path, "Test.php")
end

---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@return boolean
function NeotestAdapter.filter_dir(name)
  return false
end

---Given a file path, parse all the tests within it.
---@async
---@param file_path string Absolute file path
---@return neotest.Tree | nil
function NeotestAdapter.discover_positions(path)
  if not NeotestAdapter.is_test_file(path) then
    return nil
  end

  local query = [[
    ((class_declaration
      name: (identifier) @namespace.name (#match? @namespace.name "Test")
    ) @namespace.definition)

    (method_declaration (
      (visibility_modifier)
      name: (identifier) @test.name (#match? @test.name "^test")
    ) @test.definition)
  ]]

  return lib.treesitter.parse_positions(path, query, {
    position_id = "require('neotest-testrunner.utils').make_test_id",
  })
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function NeotestAdapter.build_spec(args)
  local position = args.tree:data()

  logger.info('build_spec', position)

  if position.type == 'directory' or position.type == 'namespace' then
    return error('Position type: ' .. position.type .. ' not supported')
  end

  local program = config.get_cmd()
  local command = { program, position.path }

  if position.type == "test" then
    local filter_args = {
      "--filter",
      "\\b" .. position.name .. "\\b",
    }
    command = vim.tbl_flatten({
      command,
      filter_args,
    })
  end

  ---@type neotest.RunSpec
  return {
    command = command,
    context = { position_id = position.id },
    env = args.env or config.get_env(),
  }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
function NeotestAdapter.results(spec, result, tree)
  logger.info('results', spec, result)

  local position_id = spec.context.position_id
  return {
    [position_id] = {
      status = result.code == 0 and "passed" or "failed",
    }
  }
end


local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(NeotestAdapter, {
  __call = function(_, opts)
    if is_callable(opts.cmd) then
      config.get_cmd = opts.cmd
    elseif opts.cmd then
      config.get_cmd = function()
        return opts.cmd
      end
    end
    if is_callable(opts.root_files) then
      config.get_root_files = opts.root_files
    elseif opts.root_files then
      config.get_root_files = function()
        return opts.root_files
      end
    end
    if is_callable(opts.env) then
      config.get_env = opts.env
    elseif type(opts.env) == "table" then
      config.get_env = function()
        return opts.env
      end
    end
    if type(opts.dap) == "table" then
      dap_configuration = opts.dap
    end
    return NeotestAdapter
  end,
})

return NeotestAdapter
