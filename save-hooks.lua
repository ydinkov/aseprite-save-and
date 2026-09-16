local saveListener = nil
local beforeSaveListener = nil
local running = false
local pendingSave = nil

local DEFAULT_COMMAND = {
  enabled = true,
  command = ""
}

local function normalizePreferences(plugin)
  local prefs = plugin.preferences

  if prefs.enabled == nil then
    prefs.enabled = true
  end

  if prefs.stopOnFailure == nil then
    prefs.stopOnFailure = true
  end

  if prefs.runFromSpriteDirectory == nil then
    prefs.runFromSpriteDirectory = true
  end

  if type(prefs.commands) ~= "table" or #prefs.commands == 0 then
    prefs.commands = { DEFAULT_COMMAND }
  end

  for i, item in ipairs(prefs.commands) do
    if type(item) ~= "table" then
      prefs.commands[i] = {
        enabled = true,
        command = tostring(item or "")
      }
    else
      if item.enabled == nil then
        item.enabled = true
      end
      if type(item.command) ~= "string" then
        item.command = tostring(item.command or "")
      end
    end
  end
end

local function shellQuote(value)
  value = tostring(value or "")

  if app.os.windows then
    -- Double quote is not a valid Windows filename character, so wrapping a
    -- filesystem path is sufficient for the path variables exposed here.
    return '"' .. value .. '"'
  end

  -- POSIX single-quote escaping: ' becomes '\''.
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function replaceToken(text, token, value)
  return text:gsub(token, function()
    return value
  end)
end

local function expandCommand(command, sprite)
  local file = sprite.filename
  local dir = app.fs.filePath(file)
  local name = app.fs.fileTitle(file)
  local filename = app.fs.fileName(file)
  local ext = app.fs.fileExtension(file)

  local replacements = {
    ["{qfile}"] = shellQuote(file),
    ["{qdir}"] = shellQuote(dir),
    ["{qname}"] = shellQuote(name),
    ["{qfilename}"] = shellQuote(filename),
    ["{qext}"] = shellQuote(ext),
    ["{file}"] = file,
    ["{dir}"] = dir,
    ["{name}"] = name,
    ["{filename}"] = filename,
    ["{ext}"] = ext
  }

  local expanded = command
  for token, value in pairs(replacements) do
    expanded = replaceToken(expanded, token, value)
  end

  return expanded, dir
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

local function executeCommand(command)
  local callOk, result, reason, code = pcall(os.execute, command)

  if not callOk then
    return false, tostring(result), nil
  end

  if result == true then
    return true, reason, code or 0
  end

  if type(result) == "number" then
    return result == 0, reason, result
  end

  return false, reason, code
end

local function showFailure(command, reason, code)
  local details = {
    "Command failed:",
    command
  }

  if reason ~= nil then
    table.insert(details, "")
    table.insert(details, "Reason: " .. tostring(reason))
  end

  if code ~= nil then
    table.insert(details, "Exit code: " .. tostring(code))
  end

  app.alert {
    title = "Save Hooks",
    text = details
  }
end

local function runCommands(plugin, sprite, force, interactive)
  normalizePreferences(plugin)
  local prefs = plugin.preferences

  if not force and not prefs.enabled then
    return true, 0
  end

  if sprite == nil or not sprite.isValid or not sprite.hasAssociatedFile then
    if interactive then
      app.alert {
        title = "Save Hooks",
        text = "Save the active sprite to a file before running save hooks."
      }
    end
    return false, 0
  end

  if running then
    return false, 0
  end

  running = true
  local executed = 0
  local overallSuccess = true

  for _, item in ipairs(prefs.commands) do
    local source = item.command or ""

    if item.enabled ~= false and source:match("%S") then
      local command, dir = expandCommand(source, sprite)
      command = withWorkingDirectory(command, dir, prefs.runFromSpriteDirectory)

      print("[Aseprite Save Hooks] > " .. command)
      local success, reason, code = executeCommand(command)
      executed = executed + 1

      if not success then
        overallSuccess = false
        showFailure(command, reason, code)

        if prefs.stopOnFailure then
          break
        end
      end
    end
  end

  running = false

  if interactive and overallSuccess then
    if executed == 0 then
      app.alert {
        title = "Save Hooks",
        text = "No enabled commands are configured."
      }
    else
      app.alert {
        title = "Save Hooks",
        text = "Executed " .. tostring(executed) .. " command(s)."
      }
    end
  end

  return overallSuccess, executed
end

local function saveDialogState(dlg, plugin, count)
  local prefs = plugin.preferences
  local data = dlg.data
  local commands = {}

  prefs.enabled = data.enabled ~= false
  prefs.stopOnFailure = data.stop_on_failure ~= false
  prefs.runFromSpriteDirectory = data.run_from_sprite_directory ~= false

  for i = 1, count do
    table.insert(commands, {
      enabled = data["command_enabled_" .. tostring(i)] ~= false,
      command = data["command_" .. tostring(i)] or ""
    })
  end

  if #commands == 0 then
    commands = { DEFAULT_COMMAND }
  end

  prefs.commands = commands
end

local function showSettings(plugin)
  normalizePreferences(plugin)

  local prefs = plugin.preferences
  local commands = prefs.commands
  local count = #commands

  local dlg = Dialog {
    title = "Save Hooks",
    resizeable = true
  }

  dlg:check {
    id = "enabled",
    text = "Run hooks after Save / Save As",
    selected = prefs.enabled
  }

  dlg:check {
    id = "run_from_sprite_directory",
    text = "Run commands from the sprite directory",
    selected = prefs.runFromSpriteDirectory
  }

  dlg:check {
    id = "stop_on_failure",
    text = "Stop after the first failed command",
    selected = prefs.stopOnFailure
  }

  dlg:separator { text = "Commands" }

  for i, item in ipairs(commands) do
    local row = i

    dlg:check {
      id = "command_enabled_" .. tostring(row),
      label = tostring(row) .. ".",
      text = "Enabled",
      selected = item.enabled ~= false
    }

    dlg:entry {
      id = "command_" .. tostring(row),
      text = item.command or "",
      hexpand = true
    }

    dlg:button {
      id = "remove_" .. tostring(row),
      text = "Remove",
      onclick = function()
        saveDialogState(dlg, plugin, count)
        table.remove(plugin.preferences.commands, row)

        if #plugin.preferences.commands == 0 then
          plugin.preferences.commands = { DEFAULT_COMMAND }
        end

        dlg:close()
        showSettings(plugin)
      end
    }

    dlg:newrow { always = true }
  end

  dlg:button {
    id = "add_command",
    text = "+ Add command",
    onclick = function()
      saveDialogState(dlg, plugin, count)
      table.insert(plugin.preferences.commands, {
        enabled = true,
        command = ""
      })
      dlg:close()
      showSettings(plugin)
    end
  }

  dlg:separator { text = "Variables" }
  dlg:label { text = "{file} {dir} {name} {filename} {ext}" }
  dlg:label { text = "Quoted: {qfile} {qdir} {qname} {qfilename} {qext}" }

  dlg:separator()

  dlg:button {
    id = "run_now",
    text = "Run Now",
    onclick = function()
      saveDialogState(dlg, plugin, count)
      runCommands(plugin, app.activeSprite, true, true)
    end
  }

  dlg:button {
    id = "save_settings",
    text = "Save",
    focus = true,
    onclick = function()
      saveDialogState(dlg, plugin, count)
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

local function recordSaveStart(ev)
  if ev.name ~= "SaveFile" and ev.name ~= "SaveFileAs" then
    return
  end

  local sprite = app.activeSprite
  if sprite == nil or not sprite.isValid then
    pendingSave = nil
    return
  end

  pendingSave = {
    command = ev.name,
    spriteId = sprite.id,
    filename = sprite.filename,
    hadAssociatedFile = sprite.hasAssociatedFile,
    wasModified = sprite.isModified
  }
end

local function savedSuccessfully(ev, sprite)
  if sprite == nil or not sprite.isValid or not sprite.hasAssociatedFile then
    return false
  end

  -- A successful save leaves the document clean. This also prevents hooks
  -- from firing after cancelling a save of a modified document.
  if sprite.isModified then
    return false
  end

  if ev.name == "SaveFileAs" and pendingSave ~= nil and
     pendingSave.command == "SaveFileAs" and
     pendingSave.spriteId == sprite.id then
    -- If an already-clean, already-associated document went through Save As
    -- but its filename did not change, the file picker was most likely
    -- cancelled. Skipping here avoids a false-positive hook run. Saving As to
    -- the same exact path is the trade-off and can still be handled by Run Now.
    if pendingSave.hadAssociatedFile and
       not pendingSave.wasModified and
       pendingSave.filename == sprite.filename then
      return false
    end
  end

  return true
end

local function handleSaveFinished(plugin, ev)
  if ev.name ~= "SaveFile" and ev.name ~= "SaveFileAs" then
    return
  end

  local sprite = app.activeSprite
  local shouldRun = savedSuccessfully(ev, sprite)
  pendingSave = nil

  if shouldRun then
    runCommands(plugin, sprite, false, false)
  end
end

function init(plugin)
  normalizePreferences(plugin)

  plugin:newMenuGroup {
    id = "aseprite_save_hooks_menu",
    title = "Save Hooks",
    group = "file_scripts"
  }

  plugin:newCommand {
    id = "AsepriteSaveHooksSettings",
    title = "Settings...",
    group = "aseprite_save_hooks_menu",
    onclick = function()
      showSettings(plugin)
    end
  }

  plugin:newCommand {
    id = "AsepriteSaveHooksRunNow",
    title = "Run Now",
    group = "aseprite_save_hooks_menu",
    onclick = function()
      runCommands(plugin, app.activeSprite, true, true)
    end,
    onenabled = function()
      local sprite = app.activeSprite
      return sprite ~= nil and sprite.isValid and sprite.hasAssociatedFile
    end
  }

  plugin:newCommand {
    id = "AsepriteSaveHooksEnabled",
    title = "Enabled",
    group = "aseprite_save_hooks_menu",
    onclick = function()
      plugin.preferences.enabled = not plugin.preferences.enabled
    end,
    onchecked = function()
      return plugin.preferences.enabled == true
    end
  }

  beforeSaveListener = app.events:on("beforecommand", recordSaveStart)

  saveListener = app.events:on("aftercommand", function(ev)
    if running then
      return
    end
    handleSaveFinished(plugin, ev)
  end)
end

function exit(plugin)
  if beforeSaveListener ~= nil then
    app.events:off(beforeSaveListener)
    beforeSaveListener = nil
  end

  if saveListener ~= nil then
    app.events:off(saveListener)
    saveListener = nil
  end
end
