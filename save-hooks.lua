local afterCommandListener = nil
local beforeCommandListener = nil
local running = false
local suppressHooks = false
local pendingCommand = nil

local TRIGGERS = {
  { key = "save", label = "Save", command = "SaveFile" },
  { key = "saveAs", label = "Save As", command = "SaveFileAs" },
  { key = "saveAll", label = "Save All (extension command)", command = "SaveAll" },
  { key = "export", label = "Export / Save Copy As", command = "SaveFileCopyAs" },
  { key = "exportSpriteSheet", label = "Export Sprite Sheet", command = "ExportSpriteSheet" },
  { key = "exportTileset", label = "Export Tileset", command = "ExportTileset" },
  { key = "repeatLastExport", label = "Repeat Last Export", command = "RepeatLastExport" },
  { key = "saveSelection", label = "Save Selection", command = "SaveMask" },
  { key = "savePalette", label = "Save Palette", command = "SavePalette" }
}

local COMMAND_TO_TRIGGER = {}
for _, trigger in ipairs(TRIGGERS) do
  if trigger.command ~= "SaveAll" then
    COMMAND_TO_TRIGGER[trigger.command] = trigger.key
  end
end

local function normalizePreferences(plugin)
  local prefs = plugin.preferences

  if prefs.enabled == nil then
    prefs.enabled = true
  end

  if type(prefs.scriptPath) ~= "string" then
    prefs.scriptPath = ""
  end

  if type(prefs.scriptArguments) ~= "string" then
    prefs.scriptArguments = ""
  end

  if prefs.runFromSpriteDirectory == nil then
    prefs.runFromSpriteDirectory = true
  end

  if type(prefs.triggers) ~= "table" then
    prefs.triggers = {}
  end

  -- Preserve the original behaviour on upgrade: Save + Save As enabled.
  if prefs.triggers.save == nil then
    prefs.triggers.save = true
  end
  if prefs.triggers.saveAs == nil then
    prefs.triggers.saveAs = true
  end

  for _, trigger in ipairs(TRIGGERS) do
    if prefs.triggers[trigger.key] == nil then
      prefs.triggers[trigger.key] = false
    end
  end
end

local function shellQuote(value)
  value = tostring(value or "")

  if app.os.windows then
    -- Windows filenames cannot contain a double quote. The complete command
    -- gets an additional pair of quotes immediately before os.execute().
    return '"' .. value .. '"'
  end

  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function replaceToken(text, token, value)
  return text:gsub(token, function()
    return value
  end)
end

local function spriteContext(sprite)
  local file = ""

  if sprite ~= nil and sprite.isValid and sprite.filename ~= nil then
    file = sprite.filename
  end

  return {
    file = file,
    dir = file ~= "" and app.fs.filePath(file) or "",
    name = file ~= "" and app.fs.fileTitle(file) or "",
    filename = file ~= "" and app.fs.fileName(file) or "",
    ext = file ~= "" and app.fs.fileExtension(file) or ""
  }
end

local function expandText(text, sprite, hookKey, commandName)
  local ctx = spriteContext(sprite)
  local hook = hookKey or "manual"
  local command = commandName or "Manual"

  local replacements = {
    ["{qfile}"] = shellQuote(ctx.file),
    ["{qdir}"] = shellQuote(ctx.dir),
    ["{qname}"] = shellQuote(ctx.name),
    ["{qfilename}"] = shellQuote(ctx.filename),
    ["{qext}"] = shellQuote(ctx.ext),
    ["{qhook}"] = shellQuote(hook),
    ["{qcommand}"] = shellQuote(command),
    ["{file}"] = ctx.file,
    ["{dir}"] = ctx.dir,
    ["{name}"] = ctx.name,
    ["{filename}"] = ctx.filename,
    ["{ext}"] = ctx.ext,
    ["{hook}"] = hook,
    ["{command}"] = command
  }

  local expanded = text or ""
  for token, value in pairs(replacements) do
    expanded = replaceToken(expanded, token, value)
  end

  return expanded, ctx
end

local function scriptInvocation(scriptPath)
  local ext = string.lower(app.fs.fileExtension(scriptPath) or "")
  local quoted = shellQuote(scriptPath)

  if app.os.windows then
    if ext == "bat" or ext == "cmd" then
      return "call " .. quoted
    elseif ext == "ps1" then
      return "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " .. quoted
    elseif ext == "sh" or ext == "bash" or ext == "command" then
      return "bash " .. quoted
    end
  else
    if ext == "sh" or ext == "command" then
      return "sh " .. quoted
    elseif ext == "bash" then
      return "bash " .. quoted
    elseif ext == "ps1" then
      return "pwsh -NoProfile -File " .. quoted
    end
  end

  return quoted
end

local function withWorkingDirectory(command, dir, enabled)
  if not enabled or dir == nil or dir == "" then
    return command
  end

  if app.os.windows then
    return "cd /d " .. shellQuote(dir) .. " && " .. command
  end

  return "cd " .. shellQuote(dir) .. " && " .. command
end

local function commandForOsExecute(command)
  if app.os.windows then
    -- Aseprite's os.execute() ultimately goes through the Windows command
    -- processor. If any part of the command contains quoted paths, cmd.exe can
    -- consume the first quote as its own wrapper and misparse the rest. An
    -- extra outer pair of quotes makes the complete command one /C payload.
    return '"' .. command .. '"'
  end

  return command
end

local function executeCommand(command)
  local shellCommand = commandForOsExecute(command)
  print("[Aseprite Save & Run] shell > " .. shellCommand)

  local callOk, result, reason, code = pcall(os.execute, shellCommand)

  if not callOk then
    return false, tostring(result), nil, shellCommand
  end

  if result == true then
    return true, reason, code or 0, shellCommand
  end

  if type(result) == "number" then
    return result == 0, reason, result, shellCommand
  end

  return false, reason, code, shellCommand
end

local function showFailure(command, shellCommand, reason, code)
  local details = {
    "Script failed.",
    "",
    "Command:",
    command
  }

  if shellCommand ~= nil and shellCommand ~= command then
    table.insert(details, "")
    table.insert(details, "Windows shell command:")
    table.insert(details, shellCommand)
  end

  if reason ~= nil then
    table.insert(details, "")
    table.insert(details, "Reason: " .. tostring(reason))
  end

  if code ~= nil then
    table.insert(details, "Exit code: " .. tostring(code))
  end

  app.alert {
    title = "Save & Run",
    text = details
  }
end

local function runScript(plugin, sprite, hookKey, commandName, interactive)
  normalizePreferences(plugin)
  local prefs = plugin.preferences

  if running then
    return false
  end

  if prefs.scriptPath == nil or not prefs.scriptPath:match("%S") then
    if interactive then
      app.alert {
        title = "Save & Run",
        text = "Choose a script in Settings first."
      }
    end
    return false
  end

  if not app.fs.isFile(prefs.scriptPath) then
    app.alert {
      title = "Save & Run",
      text = {
        "The configured script does not exist:",
        prefs.scriptPath,
        "",
        "Open Settings and select the script again."
      }
    }
    return false
  end

  local args, ctx = expandText(prefs.scriptArguments or "", sprite, hookKey, commandName)
  local command = scriptInvocation(prefs.scriptPath)

  if args:match("%S") then
    command = command .. " " .. args
  end

  command = withWorkingDirectory(command, ctx.dir, prefs.runFromSpriteDirectory)

  print("[Aseprite Save & Run] " .. tostring(commandName or "Manual") .. " > " .. command)

  running = true
  local success, reason, code, shellCommand = executeCommand(command)
  running = false

  if not success then
    showFailure(command, shellCommand, reason, code)
    return false
  end

  if interactive then
    app.alert {
      title = "Save & Run",
      text = "Script completed successfully."
    }
  end

  return true
end

local function triggerEnabled(plugin, key)
  normalizePreferences(plugin)
  return plugin.preferences.enabled == true and plugin.preferences.triggers[key] == true
end

local function saveSettingsFromDialog(dlg, plugin)
  local data = dlg.data
  local prefs = plugin.preferences

  prefs.enabled = data.enabled ~= false
  prefs.scriptPath = data.script_path or ""
  prefs.scriptArguments = data.script_arguments or ""
  prefs.runFromSpriteDirectory = data.run_from_sprite_directory ~= false

  for _, trigger in ipairs(TRIGGERS) do
    prefs.triggers[trigger.key] = data["trigger_" .. trigger.key] == true
  end
end

local function showSettings(plugin)
  normalizePreferences(plugin)
  local prefs = plugin.preferences

  local dlg = Dialog {
    title = "Save & Run Settings",
    resizeable = true
  }

  dlg:check {
    id = "enabled",
    text = "Enable automatic hooks",
    selected = prefs.enabled
  }

  dlg:file {
    id = "script_path",
    label = "Script:",
    title = "Select shell script",
    filename = prefs.scriptPath,
    open = true,
    entry = true
  }

  dlg:entry {
    id = "script_arguments",
    label = "Arguments:",
    text = prefs.scriptArguments,
    hexpand = true
  }

  dlg:check {
    id = "run_from_sprite_directory",
    text = "Run from the active sprite directory",
    selected = prefs.runFromSpriteDirectory
  }

  dlg:separator { text = "Run after" }

  for _, trigger in ipairs(TRIGGERS) do
    dlg:check {
      id = "trigger_" .. trigger.key,
      text = trigger.label,
      selected = prefs.triggers[trigger.key] == true
    }
  end

  dlg:separator { text = "Argument variables" }
  dlg:label { text = "{file} {dir} {name} {filename} {ext} {hook} {command}" }
  dlg:label { text = "Quoted forms: {qfile} {qdir} {qname} {qfilename} {qext} {qhook} {qcommand}" }

  dlg:separator()

  dlg:button {
    id = "run_now",
    text = "Run Script Now",
    onclick = function()
      saveSettingsFromDialog(dlg, plugin)
      runScript(plugin, app.sprite, "manual", "Manual", true)
    end
  }

  dlg:button {
    id = "save_settings",
    text = "Save",
    focus = true,
    onclick = function()
      saveSettingsFromDialog(dlg, plugin)
      dlg:close()
    end
  }

  dlg:button {
    id = "cancel",
    text = "Cancel",
    onclick = function()
      dlg:close()
    end
  }

  dlg:show { autoscrollbars = true }
end

local function recordCommandStart(ev)
  local hookKey = COMMAND_TO_TRIGGER[ev.name]
  if hookKey == nil then
    return
  end

  local sprite = app.sprite
  pendingCommand = {
    name = ev.name,
    hookKey = hookKey,
    sprite = sprite,
    spriteId = sprite ~= nil and sprite.id or nil,
    filename = sprite ~= nil and sprite.filename or "",
    hadAssociatedFile = sprite ~= nil and sprite.hasAssociatedFile or false,
    wasModified = sprite ~= nil and sprite.isModified or false
  }
end

local function saveSucceeded(ev, sprite)
  if sprite == nil or not sprite.isValid or not sprite.hasAssociatedFile then
    return false
  end

  if sprite.isModified then
    return false
  end

  if ev.name == "SaveFileAs" and pendingCommand ~= nil and
     pendingCommand.name == "SaveFileAs" and
     pendingCommand.spriteId == sprite.id then
    if pendingCommand.hadAssociatedFile and
       not pendingCommand.wasModified and
       pendingCommand.filename == sprite.filename then
      return false
    end
  end

  return true
end

local function handleCommandFinished(plugin, ev)
  if suppressHooks or running then
    return
  end

  local hookKey = COMMAND_TO_TRIGGER[ev.name]
  if hookKey == nil then
    return
  end

  local sprite = app.sprite
  if pendingCommand ~= nil and pendingCommand.name == ev.name and
     pendingCommand.sprite ~= nil and pendingCommand.sprite.isValid then
    sprite = pendingCommand.sprite
  end

  if ev.name == "SaveFile" or ev.name == "SaveFileAs" then
    local succeeded = saveSucceeded(ev, sprite)
    pendingCommand = nil

    if succeeded and triggerEnabled(plugin, hookKey) then
      runScript(plugin, sprite, hookKey, ev.name, false)
    end
    return
  end

  pendingCommand = nil

  -- Export-style commands do not expose a success/cancel result through the
  -- aftercommand event. Run after the command returns when that hook is enabled.
  if triggerEnabled(plugin, hookKey) then
    runScript(plugin, sprite, hookKey, ev.name, false)
  end
end

local function saveAll(plugin)
  normalizePreferences(plugin)

  local saved = 0
  local skipped = 0
  local failed = 0
  local contextSprite = app.sprite

  suppressHooks = true

  for _, sprite in ipairs(app.sprites) do
    if sprite.isValid and sprite.isModified then
      if sprite.hasAssociatedFile and sprite.filename ~= "" then
        local callOk, result = pcall(function()
          return sprite:saveAs(sprite.filename)
        end)

        if callOk and result ~= false then
          saved = saved + 1
          contextSprite = sprite
        else
          failed = failed + 1
        end
      else
        skipped = skipped + 1
      end
    end
  end

  suppressHooks = false

  if triggerEnabled(plugin, "saveAll") then
    runScript(plugin, contextSprite, "saveAll", "SaveAll", false)
  end

  local summary = { "Saved " .. tostring(saved) .. " modified file(s)." }
  if skipped > 0 then
    table.insert(summary, tostring(skipped) .. " unsaved file(s) were skipped; use Save As first.")
  end
  if failed > 0 then
    table.insert(summary, tostring(failed) .. " file(s) could not be saved.")
  end

  app.alert {
    title = "Save All",
    text = summary
  }
end

function init(plugin)
  normalizePreferences(plugin)

  plugin:newMenuGroup {
    id = "aseprite_save_and_menu",
    title = "Save & Run",
    group = "file_scripts"
  }

  plugin:newCommand {
    id = "AsepriteSaveAndSettings",
    title = "Settings...",
    group = "aseprite_save_and_menu",
    onclick = function()
      showSettings(plugin)
    end
  }

  plugin:newCommand {
    id = "AsepriteSaveAndRunNow",
    title = "Run Script Now",
    group = "aseprite_save_and_menu",
    onclick = function()
      runScript(plugin, app.sprite, "manual", "Manual", true)
    end
  }

  plugin:newCommand {
    id = "AsepriteSaveAndSaveAll",
    title = "Save All",
    group = "aseprite_save_and_menu",
    onclick = function()
      saveAll(plugin)
    end,
    onenabled = function()
      return #app.sprites > 0
    end
  }

  plugin:newCommand {
    id = "AsepriteSaveAndEnabled",
    title = "Automatic Hooks Enabled",
    group = "aseprite_save_and_menu",
    onclick = function()
      plugin.preferences.enabled = not plugin.preferences.enabled
    end,
    onchecked = function()
      return plugin.preferences.enabled == true
    end
  }

  beforeCommandListener = app.events:on("beforecommand", recordCommandStart)
  afterCommandListener = app.events:on("aftercommand", function(ev)
    handleCommandFinished(plugin, ev)
  end)
end

function exit(plugin)
  if beforeCommandListener ~= nil then
    app.events:off(beforeCommandListener)
    beforeCommandListener = nil
  end

  if afterCommandListener ~= nil then
    app.events:off(afterCommandListener)
    afterCommandListener = nil
  end
end
