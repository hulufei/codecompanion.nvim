local adapters = require("codecompanion.adapters")
local client = require("codecompanion.client")
local config = require("codecompanion").config
local keymaps = require("codecompanion.utils.keymaps")
local schema = require("codecompanion.schema")

local hash = require("codecompanion.utils.hash")
local log = require("codecompanion.utils.log")
local ui = require("codecompanion.utils.ui")
local util = require("codecompanion.utils.util")
local yaml = require("codecompanion.utils.yaml")

local api = vim.api

local CONSTANTS = {
  NS_HEADER = "CodeCompanion-headers",
  NS_INTRO = "CodeCompanion-intro_message",
  NS_VIRTUAL_TEXT = "CodeCompanion-virtual_text",

  AUTOCMD_GROUP = "codecompanion.chat",

  STATUS_ERROR = "error",
  STATUS_SUCCESS = "success",
  STATUS_FINISHED = "finished",

  USER_ROLE = "user",
  LLM_ROLE = "llm",
  SYSTEM_ROLE = "system",

  BLANK_DESC = "[No messages]",
}

local llm_role = config.strategies.chat.roles.llm
local user_role = config.strategies.chat.roles.user

---@param bufnr integer
---@return nil
local function lock_buf(bufnr)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
end

---@param bufnr integer
---@return nil
local function unlock_buf(bufnr)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = true
end

---Make an id from a string or table
---@param val string|table
---@return number
local function make_id(val)
  return hash.hash(val)
end

local _cached_settings = {}

---Parse the chat buffer for settings
---@param bufnr integer
---@param adapter? CodeCompanion.Adapter
---@param ts_query? string
---@return table
local function buf_parse_settings(bufnr, adapter, ts_query)
  if _cached_settings[bufnr] then
    return _cached_settings[bufnr]
  end

  -- If the user has disabled settings in the chat buffer, use the default settings
  if not config.display.chat.show_settings then
    if adapter then
      _cached_settings[bufnr] = adapter:get_default_settings()

      return _cached_settings[bufnr]
    end
  end

  ts_query = ts_query or [[
    ((block_mapping (_)) @block)
  ]]

  local settings = {}
  local parser = vim.treesitter.get_parser(bufnr, "yaml", { ignore_injections = false })
  local query = vim.treesitter.query.parse("yaml", ts_query)
  local root = parser:parse()[1]:root()

  for _, match in query:iter_matches(root, bufnr) do
    local value = vim.treesitter.get_node_text(match[1], bufnr)

    settings = yaml.decode(value)
    break
  end

  if not settings then
    log:error("Failed to parse settings in chat buffer")
    return {}
  end

  return settings
end

---Parse the chat buffer for the last message
---@param bufnr integer
---@return table{content: string}
local function buf_parse_message(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  local query = vim.treesitter.query.parse(
    "markdown",
    [[
(section
  (atx_heading
    (atx_h2_marker))
  ((_) @content)+) @response
]]
  )
  local root = parser:parse()[1]:root()

  local last_section = nil
  local contents = {}

  for id, node in query:iter_captures(root, bufnr) do
    if query.captures[id] == "response" then
      last_section = node
      contents = {}
    elseif query.captures[id] == "content" and last_section then
      table.insert(contents, vim.treesitter.get_node_text(node, bufnr))
    end
  end

  if #contents > 0 then
    return { content = vim.trim(table.concat(contents, "\n")) }
  end

  return {}
end

---Parse the chat buffer for all messages
---@param bufnr integer
---@return table
local function buf_parse_messages(bufnr)
  local output = {}

  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  local query = vim.treesitter.query.parse(
    "markdown",
    [[(
  atx_heading
  (atx_h2_marker)
  heading_content: (_) @role
)
(
  section
  [(paragraph) (fenced_code_block) (list)] @content
)
]]
  )
  local root = parser:parse()[1]:root()

  local captures = {}
  for k, v in pairs(query.captures) do
    captures[v] = k
  end

  local message = {}
  for _, match in query:iter_matches(root, bufnr) do
    if match[captures.role] then
      if not vim.tbl_isempty(message) then
        table.insert(output, message)
        message = { role = "", content = "" }
      end
      message.role = vim.trim(vim.treesitter.get_node_text(match[captures.role], bufnr):lower())
    elseif match[captures.content] then
      local content = vim.trim(vim.treesitter.get_node_text(match[captures.content], bufnr))
      if message.content then
        message.content = message.content .. "\n\n" .. content
      else
        message.content = content
      end
      if not message.role then
        message.role = CONSTANTS.USER_ROLE
      end
    end
  end

  if not vim.tbl_isempty(message) then
    table.insert(output, message)
  end

  return output
end

---@class CodeCompanion.Chat
---@return CodeCompanion.ToolExecuteResult|nil
local function buf_parse_tools(chat)
  local assistant_parser = vim.treesitter.get_parser(chat.bufnr, "markdown")
  local assistant_query = vim.treesitter.query.parse(
    "markdown",
    string.format(
      [[
(
  (section
    (atx_heading) @heading
    (#match? @heading "## %s")
  ) @content
)
  ]],
      llm_role
    )
  )
  local assistant_tree = assistant_parser:parse()[1]

  local assistant_response = {}
  for id, node in assistant_query:iter_captures(assistant_tree:root(), chat.bufnr, 0, -1) do
    local name = assistant_query.captures[id]
    if name == "content" then
      local response = vim.treesitter.get_node_text(node, chat.bufnr)
      table.insert(assistant_response, response)
    end
  end

  local response = assistant_response[#assistant_response]

  local parser = vim.treesitter.get_string_parser(response, "markdown")
  local tree = parser:parse()[1]
  local query = vim.treesitter.query.parse(
    "markdown",
    [[(
 (section
  (fenced_code_block
    (info_string) @lang
    (code_fence_content) @tool
  ) (#match? @lang "xml"))
)
]]
  )

  local tools = {}
  for id, node in query:iter_captures(tree:root(), response, 0, -1) do
    local name = query.captures[id]
    if name == "tool" then
      local tool = vim.treesitter.get_node_text(node, response)
      table.insert(tools, tool)
    end
  end

  log:debug("Tool detected: %s", tools)

  --TODO: Parse XML to ensure the STag is <agent>

  if tools and #tools > 0 then
    return require("codecompanion.tools").run(chat, tools[#tools])
  end
end

---Used to store all of the open chat buffers
---@type table<CodeCompanion.Chat>
local chatmap = {}

---Used to record the last chat buffer that was opened
---@type CodeCompanion.Chat|nil
local last_chat = {}

local registered_cmp = false

---@class CodeCompanion.Chat
---@field opts CodeCompanion.ChatArgs Store all arguments in this table
---@field adapter CodeCompanion.Adapter The adapter to use for the chat
---@field aug number The ID for the autocmd group
---@field bufnr integer The buffer number of the chat
---@field context table The context of the buffer that the chat was initiated from
---@field current_request table|nil The current request being executed
---@field current_tool table The current tool being executed
---@field header_ns integer The namespace for the virtual text that appears in the header
---@field id integer The unique identifier for the chat
---@field intro_message? boolean Whether the welcome message has been shown
---@field messages? table The table containing the messages in the chat buffer
---@field settings? table The settings that are used in the adapter of the chat buffer
---@field tokens? nil|number The number of tokens in the chat
---@field tools? CodeCompanion.Tools The tools available to the user
---@field tools_in_use? nil|table The tools that are currently being used in the chat
---@field variables? CodeCompanion.Variables The variables available to the user
local Chat = {}

---@class CodeCompanion.ChatArgs Arguments that can be injected into the chat
---@field context? table Context of the buffer that the chat was initiated from
---@field adapter? CodeCompanion.Adapter The adapter used in this chat buffer
---@field settings? table The settings that are used in the adapter of the chat buffer
---@field messages? table The messages to display in the chat buffer
---@field auto_submit? boolean Automatically submit the chat when the chat buffer is created
---@field stop_context_insertion? boolean Stop any visual selection from being automatically inserted into the chat buffer
---@field tokens? table Total tokens spent in the chat buffer so far
---@field status? string The status of any running jobs in the chat buffe
---@field last_role? string The role of the last response in the chat buffer

---@param args CodeCompanion.ChatArgs
function Chat.new(args)
  local id = math.random(10000000)
  log:trace("Chat created with ID %d", id)

  local self = setmetatable({
    opts = args,
    aug = api.nvim_create_augroup(CONSTANTS.AUTOCMD_GROUP .. id, {
      clear = false,
    }),
    context = args.context,
    header_ns = api.nvim_create_namespace(CONSTANTS.NS_HEADER),
    id = id,
    last_role = args.last_role or "user",
    messages = args.messages or {},
    status = "",
    tokens = args.tokens,
    tools = require("codecompanion.strategies.chat.tools").new(),
    tools_in_use = {},
    variables = require("codecompanion.strategies.chat.variables").new(),
    create_buf = function()
      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(bufnr, string.format("[CodeCompanion] %d", id))
      api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
      api.nvim_buf_set_option(bufnr, "filetype", "codecompanion")

      return bufnr
    end,
  }, { __index = Chat })

  self.bufnr = self.create_buf()
  table.insert(chatmap, {
    name = "Chat " .. #chatmap + 1,
    description = CONSTANTS.BLANK_DESC,
    strategy = "chat",
    chat = self,
  })

  self.adapter = adapters.resolve(self.opts.adapter)
  if not self.adapter then
    return log:error("No adapter found")
  end
  util.fire("ChatAdapter", { bufnr = self.bufnr, adapter = self.adapter })
  self:apply_settings(self.opts.settings)

  self.close_last_chat()
  self:open():render(self.messages):set_system_message():set_extmarks():set_autocmds()

  if self.opts.auto_submit then
    self:submit()
  end

  last_chat = self
  return self
end

---Apply custom settings to the chat buffer
---@param settings table
---@return self
function Chat:apply_settings(settings)
  _cached_settings = {}
  self.settings = settings or schema.get_default(self.adapter.schema, self.opts.settings)

  return self
end

---Set a model in the chat buffer
---@param model string
---@return self
function Chat:apply_model(model)
  if _cached_settings[self.bufnr] then
    _cached_settings[self.bufnr].model = model
  end

  self.adapter.schema.model.default = model

  return self
end

---Open/create the chat window
function Chat:open()
  if self:is_visible() then
    return
  end

  local window = config.display.chat.window
  local width = window.width > 1 and window.width or math.floor(vim.o.columns * window.width)
  local height = window.height > 1 and window.height or math.floor(vim.o.lines * window.height)

  if window.layout == "float" then
    local win_opts = {
      relative = window.relative,
      width = width,
      height = height,
      row = window.row or math.floor((vim.o.lines - height) / 2),
      col = window.col or math.floor((vim.o.columns - width) / 2),
      border = window.border,
      title = "Code Companion",
      title_pos = "center",
      zindex = 45,
    }
    self.winnr = api.nvim_open_win(self.bufnr, true, win_opts)
  elseif window.layout == "vertical" then
    local cmd = "vsplit"
    if width ~= 0 then
      cmd = width .. cmd
    end
    vim.cmd(cmd)
    self.winnr = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.winnr, self.bufnr)
  elseif window.layout == "horizontal" then
    local cmd = "split"
    if height ~= 0 then
      cmd = height .. cmd
    end
    vim.cmd(cmd)
    self.winnr = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.winnr, self.bufnr)
  else
    self.winnr = api.nvim_get_current_win()
    api.nvim_set_current_buf(self.bufnr)
  end

  ui.set_win_options(self.winnr, window.opts)
  vim.bo[self.bufnr].textwidth = 0
  ui.buf_scroll_to_end(self.bufnr)
  keymaps.set(config.strategies.chat.keymaps, self.bufnr, self)

  log:trace("Chat opened with ID %d", self.id)

  return self
end

---Render the settings and any messages in the chat buffer
---@param messages? table
---@return self
function Chat:render(messages)
  local lines = {}
  local last_role = CONSTANTS.USER_ROLE

  local function spacer()
    table.insert(lines, "")
  end

  local function set_header(role)
    table.insert(lines, string.format("## %s", role))
    spacer()
    spacer()
  end

  local function set_messages(msgs)
    for i, msg in ipairs(msgs) do
      if msg.role ~= CONSTANTS.SYSTEM_ROLE or (msg.opts and msg.opts.visible ~= false) then
        if i > 1 and last_role ~= msg.role then
          spacer()
        end
        if msg.role == CONSTANTS.USER_ROLE then
          set_header(user_role)
        end
        if msg.role == CONSTANTS.LLM_ROLE then
          set_header(llm_role)
        end

        for _, text in ipairs(vim.split(msg.content, "\n", { plain = true, trimempty = true })) do
          table.insert(lines, text)
        end

        last_role = msg.role
      end
    end
  end

  if config.display.chat.show_settings then
    log:trace("Showing chat settings")
    lines = { "---" }
    local keys = schema.get_ordered_keys(self.adapter.schema)
    for _, key in ipairs(keys) do
      local setting = self.settings[key]
      if type(setting) == "function" then
        setting = setting(self.adapter)
      end

      table.insert(lines, string.format("%s: %s", key, yaml.encode(setting)))
    end
    table.insert(lines, "---")
    spacer()
  end

  if not messages or #messages == 0 then
    log:trace("Setting the header for the chat buffer")
    set_header(user_role)
  end

  if messages then
    log:trace("Setting the messages in the chat buffer")
    set_messages(messages)
  end

  -- If the user has visually selected some text, add that to the chat buffer
  if self.context and self.context.is_visual and not self.opts.stop_context_insertion then
    log:trace("Adding visual selection to chat buffer")
    spacer()
    table.insert(lines, "```" .. self.context.filetype)
    for _, line in ipairs(self.context.lines) do
      table.insert(lines, line)
    end
    table.insert(lines, "```")
  end

  unlock_buf(self.bufnr)
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  self:render_headers()

  ui.buf_scroll_to_end(self.bufnr)

  return self
end

---Set the autocmds for the chat buffer
---@return nil
function Chat:set_autocmds()
  local bufnr = self.bufnr

  -- Setup completion
  api.nvim_create_autocmd("InsertEnter", {
    group = self.aug,
    buffer = bufnr,
    once = true,
    desc = "Setup the completion of helpers in the chat buffer",
    callback = function()
      local has_cmp, cmp = pcall(require, "cmp")
      if has_cmp then
        if not registered_cmp then
          registered_cmp = true
          cmp.register_source("codecompanion_helpers", require("cmp_codecompanion.helpers").new())
          cmp.register_source("codecompanion_models", require("cmp_codecompanion.models").new())
        end
        cmp.setup.buffer({
          enabled = true,
          sources = {
            { name = "codecompanion_helpers" },
            { name = "codecompanion_models" },
          },
        })
      end
    end,
  })

  if config.display.chat.show_settings then
    api.nvim_create_autocmd("CursorMoved", {
      group = self.aug,
      buffer = bufnr,
      desc = "Show settings information in the CodeCompanion chat buffer",
      callback = function()
        self:on_cursor_moved()
      end,
    })

    -- Validate the settings
    api.nvim_create_autocmd("InsertLeave", {
      group = self.aug,
      buffer = bufnr,
      desc = "Parse the settings in the CodeCompanion chat buffer for any errors",
      callback = function()
        local settings = buf_parse_settings(bufnr, self.adapter, [[((stream (_)) @block)]])

        local errors = schema.validate(self.adapter.schema, settings, self.adapter)
        local node = settings.__ts_node

        local items = {}
        if errors and node then
          for child in node:iter_children() do
            assert(child:type() == "block_mapping_pair")
            local key = vim.treesitter.get_node_text(child:named_child(0), bufnr)
            if errors[key] then
              local lnum, col, end_lnum, end_col = child:range()
              table.insert(items, {
                lnum = lnum,
                col = col,
                end_lnum = end_lnum,
                end_col = end_col,
                severity = vim.diagnostic.severity.ERROR,
                message = errors[key],
              })
            end
          end
        end
        vim.diagnostic.set(config.ERROR_NS, bufnr, items)
      end,
    })
  end

  api.nvim_create_autocmd("BufWriteCmd", {
    group = self.aug,
    buffer = bufnr,
    desc = "Submit the CodeCompanion chat buffer",
    callback = function()
      self:submit()
    end,
  })

  api.nvim_create_autocmd("InsertEnter", {
    group = self.aug,
    buffer = bufnr,
    once = true,
    desc = "Clear the virtual text in the CodeCompanion chat buffer",
    callback = function()
      local ns_id = api.nvim_create_namespace(CONSTANTS.NS_VIRTUAL_TEXT)
      api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end,
  })

  api.nvim_create_autocmd("BufEnter", {
    group = self.aug,
    buffer = bufnr,
    desc = "Log the most recent chat buffer",
    callback = function()
      last_chat = self
    end,
  })

  -- For when the request has completed
  api.nvim_create_autocmd("User", {
    group = self.aug,
    desc = "Listen for chat completion",
    pattern = "CodeCompanionRequestFinished",
    callback = function(request)
      if request.data.bufnr ~= self.bufnr then
        return
      end
      self:done()
    end,
  })
end

---Set any extmarks in the chat buffer
---@return CodeCompanion.Chat|nil
function Chat:set_extmarks()
  if self.intro_message or (self.opts.messages and #self.opts.messages > 0) then
    return self
  end

  -- Welcome message
  local ns_intro = api.nvim_create_namespace(CONSTANTS.NS_INTRO)
  local id = api.nvim_buf_set_extmark(self.bufnr, ns_intro, api.nvim_buf_line_count(self.bufnr) - 1, 0, {
    virt_text = { { config.display.chat.intro_message, "CodeCompanionVirtualText" } },
    virt_text_pos = "eol",
  })
  api.nvim_create_autocmd("InsertEnter", {
    buffer = self.bufnr,
    callback = function()
      api.nvim_buf_del_extmark(self.bufnr, ns_intro, id)
    end,
  })
  self.intro_message = true

  return self
end

---Render the headers in the chat buffer and apply extmarks and separators
---@return nil
function Chat:render_headers()
  local separator = config.display.chat.messages_separator
  local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)

  for l, line in ipairs(lines) do
    if line:match("## " .. user_role .. "$") or line:match("## " .. llm_role .. "$") then
      local sep = vim.fn.strwidth(line) + 1

      if config.display.chat.show_separator then
        api.nvim_buf_set_extmark(self.bufnr, self.header_ns, l - 1, sep, {
          virt_text_win_col = sep,
          virt_text = { { string.rep(separator, vim.go.columns), "CodeCompanionChatSeparator" } },
          priority = 100,
          strict = false,
        })
      end

      -- Set the highlight group for the header
      api.nvim_buf_set_extmark(self.bufnr, self.header_ns, l - 1, 0, {
        end_col = sep + 1,
        hl_group = "CodeCompanionChatHeader",
        priority = 100,
        strict = false,
      })
    end
  end
  log:trace("Rendering headers in the chat buffer")
end

---Set the system prompt in the chat buffer
---@return CodeCompanion.Chat
function Chat:set_system_message()
  if config.opts.system_prompt then
    local system_prompt = {
      role = CONSTANTS.SYSTEM_ROLE,
      content = config.opts.system_prompt,
    }
    system_prompt.id = make_id(system_prompt)
    system_prompt.opts = { visible = false }
    table.insert(self.messages, 1, system_prompt)
  end
  return self
end

---Get the settings key at the current cursor position
---@param opts? table
function Chat:_get_settings_key(opts)
  opts = vim.tbl_extend("force", opts or {}, {
    lang = "yaml",
    ignore_injections = false,
  })
  local node = vim.treesitter.get_node(opts)
  while node and node:type() ~= "block_mapping_pair" do
    node = node:parent()
  end
  if not node then
    return
  end
  local key_node = node:named_child(0)
  local key_name = vim.treesitter.get_node_text(key_node, self.bufnr)
  return key_name, node
end

---Actions to take when the cursor moves in the chat buffer
---Used to show the LLM settings at the top of the buffer
---@return nil
function Chat:on_cursor_moved()
  local key_name, node = self:_get_settings_key()
  if not key_name or not node then
    vim.diagnostic.set(config.INFO_NS, self.bufnr, {})
    return
  end

  local key_schema = self.adapter.schema[key_name]
  if key_schema and key_schema.desc then
    local lnum, col, end_lnum, end_col = node:range()
    local diagnostic = {
      lnum = lnum,
      col = col,
      end_lnum = end_lnum,
      end_col = end_col,
      severity = vim.diagnostic.severity.INFO,
      message = key_schema.desc,
    }
    vim.diagnostic.set(config.INFO_NS, self.bufnr, { diagnostic })
  end
end

---Parse the last message for any tools
---@param message table|string
---@return CodeCompanion.Chat
function Chat:parse_msg_for_tools(message)
  if type(message) == "string" then
    message = { content = message }
  end

  local tools = self.tools:parse(message.content)
  if tools then
    for tool, opts in pairs(tools) do
      message.content = self.tools:replace(message.content, tool)
      message.id = make_id({ role = message.role, content = message.content })
      self.tools_in_use[tool] = opts
    end

    -- Add the agent system prompt if tools are in use
    if util.count(self.tools_in_use) > 0 then
      self:add_message(
        config.strategies.agent.tools.opts.system_prompt,
        CONSTANTS.SYSTEM_ROLE,
        { visible = false, tag = "tool" }
      )
      for _, opts in pairs(self.tools_in_use) do
        self:add_message(
          "\n\n" .. opts.system_prompt(opts.schema),
          CONSTANTS.SYSTEM_ROLE,
          { visible = false, tag = "tool" }
        )
      end
    end
  end

  return self
end

---Parse the last message for any variables
---@param message table|string
---@return CodeCompanion.Chat
function Chat:parse_msg_for_vars(message)
  if type(message) == "string" then
    message = { content = message }
  end

  local vars = self.variables:parse(self, message.content)
  if vars then
    message.content = self.variables:replace(message.content, vars)
    message.id = make_id({ role = message.role, content = message.content })
    self:add_message(vars, CONSTANTS.USER_ROLE, { visible = false, tag = "variable" })
  end

  return self
end

---Set the messages on the chat class
---@param message table|string The message from the chat buffer
---@param role string The role of the person who sent the message
---@param opts? table Options for the message
---@return CodeCompanion.Chat
function Chat:add_message(message, role, opts)
  opts = opts or { visible = true }
  if opts.visible == nil then
    opts.visible = true
  end

  if type(message) == "string" then
    message = { content = message }
  end

  message = {
    role = role,
    content = message.content,
  }
  message.id = make_id(message)
  message.opts = opts
  table.insert(self.messages, message)

  return self
end

---Submit the chat buffer's contents to the LLM
---@param opts? table
---@return nil
function Chat:submit(opts)
  opts = opts or {}

  local bufnr = self.bufnr

  local message = buf_parse_message(bufnr)
  if util.count(message) == 0 then
    return log:warn("No messages to submit")
  end

  --- If we're regenerating the response, we don't want to add the user's last
  --- message from the buffer as it sends unneccessary context to the LLM
  if not opts.regenerate then
    self:add_message(message, CONSTANTS.USER_ROLE)
  end

  message = self.messages[#self.messages]
  self:parse_msg_for_vars(message):parse_msg_for_tools(message)

  local settings = buf_parse_settings(bufnr, self.adapter)
  settings = self.adapter:map_schema_to_params(settings)

  --TODO: Remove this soon
  if config.strategies.chat.callbacks and config.strategies.chat.callbacks.on_complete then
    config.strategies.chat.callbacks.on_submit(self)
  end

  log:debug("Settings:\n%s", settings)
  log:debug("Messages:\n%s", self.messages)

  lock_buf(bufnr)
  log:info("Chat request started")
  self.current_request = client
    .new()
    :stream(settings, self.adapter:map_roles(vim.deepcopy(self.messages)), function(err, data)
      if err then
        log:error("Error: %s", err)
        return self:reset()
      end

      if data then
        self:get_tokens(data)

        local result = self.adapter.handlers.chat_output(data)
        if result and result.status == CONSTANTS.STATUS_SUCCESS then
          if result.output.role then
            result.output.role = CONSTANTS.LLM_ROLE
          end
          self:append_to_buf(result.output)
        end
      end
    end, function()
      self.current_request = nil
    end, {
      bufnr = bufnr,
    })
end

---After the response from the LLM is received...
---@return nil
function Chat:done()
  self:add_message(buf_parse_message(self.bufnr), CONSTANTS.LLM_ROLE)

  self:append_to_buf({ role = CONSTANTS.USER_ROLE, content = "" })
  self:display_tokens()

  if self.status ~= CONSTANTS.STATUS_ERROR and util.count(self.tools_in_use) > 0 then
    buf_parse_tools(self)
  end

  --TODO: Remove this soon
  if config.strategies.chat.callbacks and config.strategies.chat.callbacks.on_complete then
    config.strategies.chat.callbacks.on_complete(self)
  end

  log:info("Chat request completed")
  return self:reset()
end

---Regenerate the response from the LLM
---@return nil
function Chat:regenerate()
  if self.messages[#self.messages].role == CONSTANTS.LLM_ROLE then
    table.remove(self.messages, #self.messages)
    self:append_to_buf({ role = CONSTANTS.USER_ROLE, content = "_Regenerating response..._" })
    self:submit({ regenerate = true })
  end
end

---Stop streaming the response from the LLM
---@return nil
function Chat:stop()
  local job
  if self.current_tool then
    job = self.current_tool
    self.current_tool = nil

    _G.codecompanion_cancel_tool = true
    job:shutdown()
  end
  if self.current_request then
    job = self.current_request
    self.current_request = nil
    if job then
      job:shutdown()
    end
  end
end

---Determine if the current chat buffer is active
---@return boolean
function Chat:is_active()
  return api.nvim_get_current_buf() == self.bufnr
end

---Hide the chat buffer from view
---@return nil
function Chat:hide()
  local layout = config.display.chat.window.layout

  if layout == "float" or layout == "vertical" or layout == "horizontal" then
    if self:is_active() then
      vim.cmd("hide")
    else
      api.nvim_win_hide(self.winnr)
    end
  else
    vim.cmd("buffer " .. vim.fn.bufnr("#"))
  end
end

---Close the current chat buffer
---@return nil
function Chat:close()
  if self.current_request then
    self:stop()
  end

  if last_chat and last_chat.bufnr == self.bufnr then
    last_chat = nil
  end

  local index = util.find_key(chatmap, "bufnr", self.bufnr)
  if index then
    table.remove(chatmap, index)
  end

  api.nvim_buf_delete(self.bufnr, { force = true })
  api.nvim_clear_autocmds({ group = self.aug })
  util.fire("ChatClosed", { bufnr = self.bufnr, chat = self })
  util.fire("ChatAdapter", { bufnr = self.bufnr, adapter = nil })
  self = nil
end

---Determine if the chat buffer is visible
---@return boolean
function Chat:is_visible()
  return self.winnr and api.nvim_win_is_valid(self.winnr) and api.nvim_win_get_buf(self.winnr) == self.bufnr
end

---Get the last line, column and line count in the chat buffer
---@return integer, integer, integer
function Chat:last()
  local line_count = api.nvim_buf_line_count(self.bufnr)

  local last_line = line_count - 1
  if last_line < 0 then
    return 0, 0, line_count
  end

  local last_line_content = api.nvim_buf_get_lines(self.bufnr, -2, -1, false)
  if not last_line_content or #last_line_content == 0 then
    return last_line, 0, line_count
  end

  local last_column = #last_line_content[1]

  return last_line, last_column, line_count
end

---Append a message to the chat buffer
---@param data table
---@param opts? table
function Chat:append_to_buf(data, opts)
  local lines = {}
  local bufnr = self.bufnr
  local new_response = false

  if (data.role and data.role ~= self.last_role) or (opts and opts.force_role) then
    new_response = true
    self.last_role = data.role
    table.insert(lines, "")
    table.insert(lines, "")
    table.insert(lines, string.format("## %s", config.strategies.chat.roles[data.role]))
    table.insert(lines, "")
  end

  if data.content then
    for _, text in ipairs(vim.split(data.content, "\n", { plain = true, trimempty = false })) do
      table.insert(lines, text)
    end

    unlock_buf(bufnr)

    local last_line, last_column, line_count = self:last()
    if opts and opts.insert_at then
      last_line = opts.insert_at
      last_column = 0
    end

    local cursor_moved = api.nvim_win_get_cursor(0)[1] == line_count
    api.nvim_buf_set_text(bufnr, last_line, last_column, last_line, last_column, lines)

    if new_response then
      self:render_headers()
    end

    if self.last_role ~= CONSTANTS.USER_ROLE then
      lock_buf(bufnr)
    end

    if cursor_moved and self:is_active() then
      ui.buf_scroll_to_end(bufnr)
    elseif not self:is_active() then
      ui.buf_scroll_to_end(bufnr)
    end
  end
end

---When a request has finished, reset the chat buffer
---@return nil
function Chat:reset()
  self.status = ""
  unlock_buf(self.bufnr)
end

---Get the messages from the chat buffer
---@return table
function Chat:get_messages()
  return self.messages
end

---@param data table
---@return nil
function Chat:get_tokens(data)
  if self.adapter.features.tokens then
    local tokens = self.adapter.handlers.tokens(data)
    if tokens then
      self.tokens = tokens
    end
  end
end

---Display the tokens in the chat buffer
function Chat:display_tokens()
  if config.display.chat.show_token_count and self.tokens then
    require("codecompanion.utils.tokens").display(self.tokens, self.bufnr)
  end
end

---Conceal parts of the chat buffer enclosed by a H2 heading
---@param heading string
---@return self
function Chat:conceal(heading)
  local parser = vim.treesitter.get_parser(self.bufnr, "markdown")

  local query = vim.treesitter.query.parse(
    "markdown",
    string.format(
      [[
    ((section
      ((atx_heading) @heading)
      (#eq? @heading "### %s")) @content)
  ]],
      heading
    )
  )
  local tree = parser:parse()[1]
  local root = tree:root()

  for _, captures, _ in query:iter_matches(root, self.bufnr, 0, -1, { all = true }) do
    if captures[2] then
      local node = captures[2]
      local start_row, _, end_row, _ = node[1]:range()

      if start_row < end_row then
        api.nvim_buf_set_option(self.bufnr, "foldmethod", "manual")
        api.nvim_buf_call(self.bufnr, function()
          vim.fn.setpos(".", { self.bufnr, start_row + 1, 0, 0 })
          vim.cmd("normal! zf" .. end_row .. "G")
        end)
        ui.buf_scroll_to_end(self.bufnr)
      end
    end
  end

  log:trace("Concealing %s", heading)
  return self
end

---CodeCompanion models completion source
---@param request table
---@param callback fun(request: table)
---@return nil
function Chat:complete(request, callback)
  local items = {}
  local cursor = api.nvim_win_get_cursor(0)
  local key_name, node = self:_get_settings_key({ pos = { cursor[1] - 1, 1 } })
  if not key_name or not node then
    callback({ items = items, isIncomplete = false })
    return
  end

  local key_schema = self.adapter.schema[key_name]
  if key_schema.type == "enum" then
    local choices = key_schema.choices
    if type(choices) == "function" then
      choices = choices(self.adapter)
    end
    for _, choice in ipairs(choices) do
      table.insert(items, {
        label = choice,
        kind = require("cmp").lsp.CompletionItemKind.Keyword,
      })
    end
  end

  callback({ items = items, isIncomplete = false })
end

---Clear the chat buffer
---@return nil
function Chat:clear()
  local function clear_ns(ns)
    for _, name in ipairs(ns) do
      local id = api.nvim_create_namespace(name)
      api.nvim_buf_clear_namespace(self.bufnr, id, 0, -1)
    end
  end

  local namespaces = {
    CONSTANTS.NS_INTRO,
    CONSTANTS.NS_VIRTUAL_TEXT,
    CONSTANTS.NS_HEADER,
  }

  self.messages = {}
  self.tokens = nil
  clear_ns(namespaces)

  log:trace("Clearing chat buffer")
  self:render():set_system_message():set_extmarks()
end

---Display the chat buffer's settings and messages
function Chat:debug()
  if util.count(self.messages) == 0 then
    return
  end

  return buf_parse_settings(self.bufnr, self.adapter), self.messages
end

---Returns the chat object(s) based on the buffer number
---@param bufnr? integer
---@return CodeCompanion.Chat|table
function Chat.buf_get_chat(bufnr)
  if not bufnr then
    return chatmap
  end

  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  return chatmap[util.find_key(chatmap, "bufnr", bufnr)].chat
end

---Returns the last chat that was visible
---@return CodeCompanion.Chat|nil
function Chat.last_chat()
  if util.is_empty(last_chat) then
    return nil
  end
  return last_chat
end

---Close the last chat buffer
---@return nil
function Chat.close_last_chat()
  if last_chat and not util.is_empty(last_chat) and last_chat:is_visible() then
    last_chat:hide()
  end
end

return Chat
