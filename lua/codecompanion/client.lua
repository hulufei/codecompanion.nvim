local config = require("codecompanion").config

local curl = require("plenary.curl")
local log = require("codecompanion.utils.log")
local schema = require("codecompanion.schema")
local util = require("codecompanion.utils.util")

---@class CodeCompanion.Client
---@field static table
---@field opts nil|table
---@field user_args nil|table
local Client = {}
Client.static = {}

Client.static.opts = {
  request = { default = curl.post },
  encode = { default = vim.json.encode },
  schedule = { default = vim.schedule_wrap },
}

---@class CodeCompanion.ClientArgs
---@field opts nil|table
---@field user_args nil|table

---@param args? CodeCompanion.ClientArgs
---@return CodeCompanion.Client
function Client.new(args)
  args = args or {}

  return setmetatable({
    opts = args.opts or schema.get_default(Client.static.opts, args.opts),
    user_args = args.user_args or {},
  }, { __index = Client })
end

---@param adapter CodeCompanion.Adapter
---@param payload table The messages payload to send to the LLM
---@param cb fun(err: nil|string, chunk: nil|table, done: nil|boolean) Will be called multiple times until done is true
---@param after? fun() Will be called after the request is finished
---@param opts? table Options that can be passed to the request
---@return table|nil The Plenary job
function Client:stream(adapter, payload, cb, after, opts)
  opts = opts or {}
  cb = log:wrap_cb(cb, "Response error: %s")

  if adapter.handlers.setup then
    local ok = adapter.handlers.setup(adapter)
    if not ok then
      return
    end
  end

  adapter:get_env_vars()

  local body = self.opts.encode(
    vim.tbl_extend(
      "keep",
      adapter.handlers.form_parameters(adapter, adapter:set_env_vars(adapter.parameters), payload) or {},
      adapter.handlers.form_messages(adapter, payload)
    )
  )

  log:trace("Updated Adapter:\n%s", adapter)

  local handler = self.opts
    .request({
      url = adapter:set_env_vars(adapter.url),
      headers = adapter:set_env_vars(adapter.headers),
      insecure = config.adapters.opts.allow_insecure,
      proxy = config.adapters.opts.proxy,
      raw = adapter.raw or { "--no-buffer" },
      body = body,
      stream = self.opts.schedule(function(_, data)
        if data and data ~= "" then
          log:trace("Request data:\n%s", data)
        end
        -- log:trace("----- For Adapter test creation -----\nRequest: %s\n ---------- // END ----------", data)

        cb(nil, data)
      end),
      on_error = function(err, _, code)
        if code then
          log:error("Error: %s", err)
        end
        return cb(nil, nil)
      end,
    })
    :after(function(data)
      vim.schedule(function()
        if after and type(after) == "function" then
          after()
        end
        if adapter.handlers.on_stdout then
          adapter.handlers.on_stdout(adapter, data)
        end
        if adapter.handlers.teardown then
          adapter.handlers.teardown(adapter)
        end
        util.fire("RequestFinished", opts)
        if self.user_args.event then
          util.fire("RequestFinished" .. (self.user_args.event or ""), opts)
        end
      end)
    end)

  if handler and handler.args then
    log:debug("Request:\n%s", handler.args)
  end

  util.fire("RequestStarted", opts)
  if self.user_args.event then
    util.fire("RequestStarted" .. (self.user_args.event or ""), opts)
  end

  return handler
end

return Client
