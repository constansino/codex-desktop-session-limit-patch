# Codex Desktop Session Limit Patch

This project documents and automates a local workaround for a Codex Desktop sidebar issue on Windows: when a machine has many local Codex sessions, older project folders can appear empty even though the underlying `.codex` SQLite metadata and rollout files still exist.

The workaround keeps the official Microsoft Store / WindowsApps Codex installation untouched. It builds a separate "Codex Patched" launcher from the installed official assets, patches the desktop frontend to auto-page through recent threads, and runs it with separate Electron user data so it can coexist with the official app.

## Problem

Codex Desktop's recent-thread frontend fetch used a small page size for the initial sidebar list. On a machine with hundreds of sessions, project folders outside the first loaded window could show "no conversations" even when:

- `C:\Users\<user>\.codex\state_5.sqlite` still contained the thread rows.
- `C:\Users\<user>\.codex\sessions\...` still contained rollout JSONL files.
- The app-server `thread/list` API could return those threads when paginated with `nextCursor`.

In the observed case, the official UI did not load enough recent threads for several older project folders. Direct app-server probing showed that `thread/list` supports pagination and caps each response around 100 rows even when a larger limit is requested.

## Approach

The patch changes only a copied app bundle under `%LOCALAPPDATA%\CodexSessionLimitPatch`.

It does the following:

- Finds the latest installed official `OpenAI.Codex_*_x64__2p2nqsd0c76g0` package under `C:\Program Files\WindowsApps`.
- Extracts the official `resources\app.asar`.
- Patches the minified webview asset that manages recent conversations:
  - Replaces the single initial recent-thread request with an auto-pagination loop.
  - Requests up to `1000` rows per page.
  - Follows `nextCursor` for up to `20` pages by default.
  - Raises sidebar search and load-more page sizes to `1000`.
- Patches the app title to `Codex Patched` so the patched and official windows are easy to distinguish.
- Installs an Electron runner and places the patched `app.asar` plus official resources under a separate packaged directory.
- Uses `CODEX_ELECTRON_USER_DATA_PATH` so the patched app has separate Electron cache/state from the official app.
- Creates a desktop shortcut named `Codex Patched SessionLimit.lnk`.

## What This Does Not Do

- It does not modify the official WindowsApps installation.
- It does not mutate `.codex\state_5.sqlite`.
- It does not reorder `updated_at`.
- It does not delete or rewrite session rollout files.
- It is not an upstream fix and is not affiliated with OpenAI.

## Install

Run PowerShell as a normal user:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-CodexSessionLimitPatch.ps1
```

Optional parameters:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-CodexSessionLimitPatch.ps1 -PageLimit 1000 -MaxPages 20
```

The patched app is installed under:

```text
%LOCALAPPDATA%\CodexSessionLimitPatch
```

The shortcut is created at:

```text
%USERPROFILE%\Desktop\Codex Patched SessionLimit.lnk
```

## Updating After Official Codex Updates

This patch does not automatically follow official app updates. After the official Codex Desktop app updates, rerun:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-CodexSessionLimitPatch.ps1
```

The script will copy from the newest installed official package and reapply the patch. If OpenAI changes the minified frontend structure, the script may fail with a clear pattern-matching error and need an update.

## Verify

Use:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-CodexRecentThreadList.ps1
```

This probes `codex.exe app-server` directly and prints how many threads are returned across pages.

## Upstream Suggestion

The durable fix should be in Codex Desktop itself:

- The sidebar should page through recent threads until it has enough data for project grouping, or until a user-configurable limit is reached.
- Advanced users should be able to configure the local session/sidebar cap.
- The UI should distinguish "folder has no conversations" from "conversation list is not fully loaded yet".

That would avoid local repacking and make the behavior predictable for users with large local session histories.

Related upstream discussion:

- https://github.com/openai/codex/issues/19290#issuecomment-4359469595
