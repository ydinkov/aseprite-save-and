# Aseprite Save & Run

An Aseprite extension that runs a shell script after configurable save and export actions.

## Features

- Pick a script from the extension settings UI.
- Pass optional arguments to the script.
- Choose exactly which actions trigger it:
  - Save
  - Save As
  - Save All (provided by the extension)
  - Export / Save Copy As
  - Export Sprite Sheet
  - Export Tileset
  - Repeat Last Export
  - Save Selection
  - Save Palette
- Run the script manually from **File → Scripts → Save & Run → Run Script Now**.
- Optionally run the script with the active sprite directory as the working directory.
- Use sprite and hook variables in the script arguments.
- Build an installable `.aseprite-extension` package in GitHub Actions.
- Publish the package as a GitHub Release asset for `v*` tags.

## Install

Download `aseprite-save-and-<version>.aseprite-extension` from the latest GitHub Release, then install it in Aseprite via:

**Edit → Preferences → Extensions → Add Extension**

Restart Aseprite after installing or updating the extension.

## Configure

Open:

**File → Scripts → Save & Run → Settings...**

Choose a shell script, enter any optional arguments, and enable the hooks you want.

The script picker accepts any file. Save & Run uses the file extension to choose a sensible launcher for common shell script formats:

- `.sh` / `.command` → `sh` on macOS/Linux
- `.bash` → `bash`
- `.bat` / `.cmd` → `call` on Windows
- `.ps1` → Windows PowerShell on Windows, `pwsh` on macOS/Linux
- other files are executed directly

Aseprite will ask for permission when a script first tries to execute an external command through `os.execute()`.

## Argument variables

Arguments can contain these variables:

| Variable | Value |
| --- | --- |
| `{file}` | Full sprite filename |
| `{dir}` | Sprite directory |
| `{name}` | Filename without extension |
| `{filename}` | Filename including extension |
| `{ext}` | File extension |
| `{hook}` | Save & Run hook key, e.g. `save`, `export`, `saveAll` |
| `{command}` | Aseprite command name, e.g. `SaveFile`, `ExportSpriteSheet` |

Quoted variants are available as `{qfile}`, `{qdir}`, `{qname}`, `{qfilename}`, `{qext}`, `{qhook}`, and `{qcommand}`. Prefer quoted variants when passing paths as arguments.

Example:

```text
--sprite {qfile} --event {qhook}
```

## Save All

Aseprite currently does not expose a native Save All command. The extension therefore adds **File → Scripts → Save & Run → Save All**. It saves every modified sprite that already has an associated file, skips never-saved sprites, then runs the Save All hook once if enabled.

## Export hooks

Aseprite exposes `beforecommand` and `aftercommand` events, but export-style commands do not provide a success/cancel result to extension code. Save & Run therefore executes enabled export hooks after the corresponding command returns. Save and Save As receive extra checks to avoid running after an obviously cancelled save.

## Development

The extension consists of:

```text
package.json
save-hooks.lua
LICENSE
.github/workflows/release.yml
```

The GitHub Actions workflow validates the manifest, syntax-checks the Lua source, and builds the extension on pushes and pull requests.

## Release

Update the version in `package.json`, then push a matching tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The workflow verifies the tag matches `package.json`, builds the extension, creates the GitHub Release if needed, and uploads the `.aseprite-extension` file as a release asset.

## License

MIT
