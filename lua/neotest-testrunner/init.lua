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

---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@return boolean
function NeotestAdapter.filter_dir(name)
  return false
end

---@async
---@param file_path string
---@return boolean
function NeotestAdapter.is_test_file(file_path)
  return vim.endswith(file_path, "Test.php")
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
    ;; query
    ((class_declaration
      name: (identifier) @namespace.name (#match? @namespace.name "Test")
    ) @namespace.definition)

    (method_declaration (
      (visibility_modifier)
      name: (identifier) @test.name (#match? @test.name "^test")
    ) @test.definition)
  ]]

  -- using lib.treesitter.parse_positions starts the test cmd from a new
  -- neovim headless with no config loaded process which causes all sorts
  -- of unexpected issues.
  return lib.treesitter._parse_positions(path, query, {
    position_id = "require('neotest-testrunner.utils').make_test_id",
  })
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function NeotestAdapter.build_spec(args)
  local position = args.tree:data()

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
    context = { position = { id = position.id, type = position.type } },
    env = args.env or config.get_env(),
  }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
function NeotestAdapter.results(spec, result, tree)
  local position = spec.context.position


  if result.code == 0 then
    return {
      [position.id] = {
        status = "passed",
      }
    }
  end

  if position.type == "file" then
    return {
      [position.id] = {
        -- TODO: when code == 1 we have to read result.output and
        -- see which positiones failed and which passed
        status = result.code == 0 and "passed" or "failed",
      }
    }
  end

  -- When the type is "test", the "t" command has what seems to be a bug
  -- where it returns code=1 even when all filtered tests passed.
  if position.type == "test" then
    local output_file = result.output
    local ok, output_content = pcall(lib.files.read, output_file)
    if not ok then
      logger.error("Could not get test results", output_file)
      return {}
    end
    local any_test_failed = string.find(output_content, '[(]FAILED [(]%d+[)][)]') ~= nil
    return {
      [position.id] = {
        status = any_test_failed and "failed" or "passed",
      }
    }
  end

  error('Position type: ' .. position.type .. ' not supported')
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end


local setup_config = function(config_name, opt_value)
  if is_callable(opt_value) then
    config[config_name] = opt_value
  elseif opt_value then
    config[config_name] = function()
      return opt_value
    end
  end
end

setmetatable(NeotestAdapter, {
  __call = function(_self, opts)
    setup_config('get_cmd', opts.cmd)
    setup_config('get_root_files', opts.root_files)
    setup_config('get_env', opts.env)
    return NeotestAdapter
  end,
})

return NeotestAdapter
