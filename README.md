# Aseprite Save Hooks

Run configurable terminal commands automatically after you save a sprite in Aseprite.

Aseprite Save Hooks adds **File → Scripts → Save Hooks** with:

- **Settings...** — configure the ordered command list.
- **Run Now** — execute the configured commands without saving first.
- **Enabled** — globally enable or disable automatic save hooks.

The extension listens for Aseprite's `SaveFile` and `SaveFileAs` commands and runs hooks after a successful save. `SaveFileCopyAs` / Export is intentionally not treated as a normal save.

## Install

Download `aseprite-save-hooks.aseprite-extension` from the latest GitHub Release, then either:

1. Double-click the file on Windows or macOS, or
2. In Aseprite, open **Edit → Preferences → Extensions → Add Extension** and select it.

Restart Aseprite after installation if needed.

## Configure

Open **File → Scripts → Save Hooks → Settings...**.

Each command can be enabled or disabled independently. Commands run from top to bottom. By default the extension:

- runs commands from the saved sprite's directory;
- stops when a command fails;
- shows an alert when a command exits unsuccessfully.

Aseprite asks for permission before a script is allowed to execute external commands through `os.execute()`.

### Variables

Commands support these variables:

| Variable | Value |
| --- | --- |
| `{file}` | Full path to the saved sprite |
| `{dir}` | Directory containing the sprite |
| `{name}` | Filename without extension |
| `{filename}` | Filename including extension |
| `{ext}` | File extension without the dot |
| `{qfile}` | Shell-quoted `{file}` |
| `{qdir}` | Shell-quoted `{dir}` |
| `{qname}` | Shell-quoted `{name}` |
| `{qfilename}` | Shell-quoted `{filename}` |
| `{qext}` | Shell-quoted `{ext}` |

Prefer the `q*` variants when passing paths as command-line arguments.

### Examples

Export or process the saved sprite with Python:

```text
python ./tools/process_sprite.py {qfile}
```

Run a project-local build script:

```text
./build-assets.sh {qfile}
```

On Windows:

```text
powershell -File .\\tools\\build-assets.ps1 -Sprite {qfile}
```

## Notes

`os.execute()` is synchronous. A long-running command will keep Aseprite busy until the command exits. For heavier pipelines, use a command that starts or signals a separate worker process.

The extension intentionally runs arbitrary shell commands because that is its purpose. Only configure commands you trust.

## Building locally

An Aseprite extension is a ZIP archive with an `.aseprite-extension` filename. From the repository root:

```bash
mkdir -p dist
zip -j dist/aseprite-save-hooks.aseprite-extension package.json save-hooks.lua LICENSE
```

## Releasing

The GitHub Actions workflow validates the Lua syntax and `package.json`, builds the extension on pushes and pull requests, and uploads it as a workflow artifact.

To create a GitHub Release:

1. Update the version in `package.json`, e.g. `0.2.0`.
2. Commit and push the change to `main`.
3. Create and push a matching tag, e.g. `v0.2.0`.

The workflow verifies that the tag and manifest versions match, then creates the release and attaches `aseprite-save-hooks.aseprite-extension`.

## License

MIT
