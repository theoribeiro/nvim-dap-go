local ts = require("dap-go-ts")

local M = {
  last_testname = "",
  last_testpath = "",
  test_buildflags = "",
}

local default_config = {
  delve = {
    path = "dlv",
    initialize_timeout_sec = 20,
    port = "${port}",
    args = {},
    build_flags = "",
    detached = true,
  },
}

local function load_module(module_name)
  local ok, module = pcall(require, module_name)
  assert(ok, string.format("dap-go dependency error: %s not installed", module_name))
  return module
end

local function get_arguments()
  return coroutine.create(function(dap_run_co)
    local args = {}
    vim.ui.input({ prompt = "Args: " }, function(input)
      args = vim.split(input or "", " ")
      coroutine.resume(dap_run_co, args)
    end)
  end)
end

local function filtered_pick_process()
  local opts = {}
  vim.ui.input(
    { prompt = "Search by process name (lua pattern), or hit enter to select from the process list: " },
    function(input)
      opts["filter"] = input or ""
    end
  )
  return require("dap.utils").pick_process(opts)
end

local function file_from_path(filePath)
  -- Placeholder expansion for launch directives
  local placeholders = {
    ["${file}"] = function(_)
      return vim.fn.expand("%:p")
    end,
    ["${fileBasename}"] = function(_)
      return vim.fn.expand("%:t")
    end,
    ["${fileBasenameNoExtension}"] = function(_)
      return vim.fn.fnamemodify(vim.fn.expand("%:t"), ":r")
    end,
    ["${fileDirname}"] = function(_)
      return vim.fn.expand("%:p:h")
    end,
    ["${fileExtname}"] = function(_)
      return vim.fn.expand("%:e")
    end,
    ["${relativeFile}"] = function(_)
      return vim.fn.expand("%:.")
    end,
    ["${relativeFileDirname}"] = function(_)
      return vim.fn.fnamemodify(vim.fn.expand("%:.:h"), ":r")
    end,
    ["${workspaceFolder}"] = function(_)
      return vim.fn.getcwd()
    end,
    ["${workspaceFolderBasename}"] = function(_)
      return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
    end,
    ["${env:([%w_]+)}"] = function(match)
      return os.getenv(match) or ""
    end,
  }
  for key, fn in pairs(placeholders) do
    filePath = filePath:gsub(key, fn)
  end
  return io.open(filePath, "r")
end

local function setup_delve_adapter(dap, config)
  local args = { "dap", "-l", "127.0.0.1:" .. config.delve.port }
  vim.list_extend(args, config.delve.args)

  dap.adapters.go = {
    type = "server",
    port = config.delve.port,
    executable = {
      command = config.delve.path,
      args = args,
      detached = config.delve.detached,
    },
    options = {
      initialize_timeout_sec = config.delve.initialize_timeout_sec,
    },
    enrich_config = function(finalConfig, on_config)
      local final_config = vim.deepcopy(finalConfig)

      if final_config.envFile then
        local file
        if type(final_config.envFile) == "function" then
          local filePath = final_config.envFile()
          file = file_from_path(filePath)
        else
          if type(final_config.envFile) == "table" then
            for _, v in ipairs(final_config.envFile) do
              file = file_from_path(v)
              if file then
                break
              end
            end
          end

          if file then
            for line in file:lines() do
              local words = {}
              for word in string.gmatch(line, "[^=]+") do
                table.insert(words, word)
              end
              if not final_config.env then
                final_config.env = {}
              end
              final_config.env[words[1]] = words[2]
            end
          end
        end
        on_config(final_config)
      end
    end,
  }
end

local function setup_go_configuration(dap, configs)
  dap.configurations.go = {
    {
      type = "go",
      name = "Debug",
      request = "launch",
      program = "${file}",
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug (Arguments)",
      request = "launch",
      program = "${file}",
      args = get_arguments,
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug Package",
      request = "launch",
      program = "${fileDirname}",
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Attach",
      mode = "local",
      request = "attach",
      processId = filtered_pick_process,
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug test",
      request = "launch",
      mode = "test",
      program = "${file}",
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug test (go.mod)",
      request = "launch",
      mode = "test",
      program = "./${relativeFileDirname}",
      buildFlags = configs.delve.build_flags,
    },
  }

  if configs == nil or configs.dap_configurations == nil then
    return
  end

  for _, config in ipairs(configs.dap_configurations) do
    if config.type == "go" then
      table.insert(dap.configurations.go, config)
    end
  end
end

function M.setup(opts)
  local config = vim.tbl_deep_extend("force", default_config, opts or {})
  M.test_buildflags = config.delve.build_flags
  M.debug_config = config.debug_config
  local dap = load_module("dap")
  setup_delve_adapter(dap, config)
  setup_go_configuration(dap, config)
end

local function debug_test(testname, testpath, build_flags)
  local dap = load_module("dap")

  local test_args = { "-test.run", "^" .. testname .. "$" }

  local debug_config = {
    type = "go",
    name = testname,
    request = "launch",
    mode = "test",
    program = testpath,
    args = test_args,
    buildFlags = build_flags,
  }

  if M.debug_config then
    M.debug_config.args = vim.tbl_deep_extend("force", M.debug_config.args or {}, test_args)
    M.debug_config.name = testname
  end

  dap.run(M.debug_config or debug_config)
end

function M.debug_test()
  local test = ts.closest_test()

  if test.name == "" or test.name == nil then
    vim.notify("no test found")
    return false
  end

  M.last_testname = test.name
  M.last_testpath = test.package

  local msg = string.format("starting debug session '%s : %s'...", test.package, test.name)
  vim.notify(msg)
  debug_test(test.name, test.package, M.test_buildflags)

  return true
end

function M.debug_last_test()
  local testname = M.last_testname
  local testpath = M.last_testpath

  if testname == "" then
    vim.notify("no last run test found")
    return false
  end

  local msg = string.format("starting debug session '%s : %s'...", testpath, testname)
  vim.notify(msg)
  debug_test(testname, testpath, M.test_buildflags)

  return true
end

return M
