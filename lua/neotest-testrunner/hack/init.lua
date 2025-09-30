local lib = require("neotest.lib")
local logger = require("neotest.logging")
local utils = require("neotest-testrunner.utils")
local nio = require('nio')

local config = {
  cmd = 't',
  root_files = { ".arcconfig" }
}

---@class neotest.Adapter
---@field name string
local NeotestAdapter = { name = "neotest-testrunner" }

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
function NeotestAdapter.root(dir)
  for _, root_file in ipairs(config.root_files) do
    local result = lib.files.match_root_pattern(root_file)(dir)
    if result then
      return result
    end
  end
end

---Filter directories when searching for test files
---We don't use discovery, so simply returning false.
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
  logger.info("BUILD_SPEC ARGS", args.tree:children())
  local position = args.tree:data()

  if position.type == 'directory' or position.type == 'namespace' then
    return error('Position type: ' .. position.type .. ' not supported')
  end

  local log_path = nio.fn.tempname()
  local command = { config.cmd, position.path, '--event-log-file', log_path }

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
    context = {
      position = { id = position.id, type = position.type },
      log = { path = log_path }
    },
    env = args.env,
  }
end


    ---@param args neotest.RunArgs
    ---@return neotest.RunSpec
    -- build_spec = function(args)
    --   local stream_path = nio.fn.tempname()
    --   lib.files.write(stream_path, "")
    --   local stream_data, stop_stream = lib.files.stream_lines(stream_path)
    --
    --   ---@type neotest.RunSpec
    --   return {
    --     context = {
    --       results_path = results_path,
    --       stop_stream = stop_stream,
    --     },
    --     stream = function()
    --       return function()
    --         local lines = stream_data()
    --         local results = {}
    --         for _, line in ipairs(lines) do
    --           local result = vim.json.decode(line, { luanil = { object = true } })
    --           results[result.name] = result.result
    --         end
    --         return results
    --       end
    --     end,
    --   }
    -- end,
    -- ---@param spec neotest.RunSpec
    -- ---@param result neotest.StrategyResult
    -- ---@return neotest.Result[]
    -- results = function(spec, result)
    --   spec.context.stop_stream()
    --   local success, data = pcall(lib.files.read, spec.context.results_path)
    --   if not success then
    --     data = "{}"
    --   end
    --   local results = vim.json.decode(data, { luanil = { object = true } })
    --   for _, pos_result in pairs(results) do
    --     result.output_path = pos_result.output_path
    --   end
    --   return results
    -- end,


---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
function NeotestAdapter.results(spec, result, tree)
  logger.info("RESULTS SPEC", spec)
  logger.info("RESULTS RESULT", result)

  local position = spec.context.position

  if result.code == 0 then
    return {
      [position.id] = {
        status = "passed",
      }
    }
  end

  -- log file structure
  --
  -- first line:
  -- {"type": "run_id", "id":2251800129442060}
  -- Then one line for each test run:
  -- {
  --   "test_name":"ClassName::testMethodName",
  --   "config":{},
  --   "status":3, <- 1:PASS, 2:FAIL, 3:SKIP
  --   "status_detailed":401, <- not sure what this is...
  --   "details":null,
  --   "result_id":"2251800129442060.844425137975780.1759189991",
  --   "duration_secs":22.877155464
  -- }

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
    local output_path = result.output
    local ok, output_content = pcall(lib.files.read, output_path)
    if not ok then
      logger.error("Could not get test results", output_path)
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

setmetatable(NeotestAdapter, {
  __call = function(_self)
    return NeotestAdapter
  end,
})

return NeotestAdapter
