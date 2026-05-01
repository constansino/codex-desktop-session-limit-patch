# Codex Desktop local session sidebar can show empty project folders when many sessions exist

I ran into a Codex Desktop issue on Windows where older project folders in the sidebar showed no conversations even though the sessions still existed on disk.

## What I observed

On a machine with hundreds of local Codex sessions:

- The SQLite state database still had the thread rows.
- The rollout JSONL files still existed under `.codex/sessions`.
- Direct `codex.exe app-server` calls to `thread/list` could return the missing conversations when using pagination.
- The Desktop sidebar still showed some project folders as empty, especially older folders outside the initially loaded recent-thread window.

This made it look like sessions were deleted, but they were not. The problem was that the UI had not loaded enough recent threads to populate those project groups.

## Local workaround

I made a Windows-only local workaround that keeps the official Codex app untouched:

1. Copy the installed official Codex app resources into a separate local patch directory.
2. Extract `resources/app.asar`.
3. Patch the frontend recent-thread manager so the initial recent-thread fetch follows `nextCursor` for multiple pages instead of relying on a small first page.
4. Increase the load-more and sidebar search limits to 1000.
5. Run the patched app through a separate Electron runner with its own `CODEX_ELECTRON_USER_DATA_PATH`.
6. Rename the window to `Codex Patched` so it can coexist with the official `Codex` window without confusion.

Project:

https://github.com/constansino/codex-desktop-session-limit-patch

Related issue comment:

https://github.com/openai/codex/issues/19290#issuecomment-4359469595

This does not modify `.codex/state_5.sqlite`, does not reorder `updated_at`, and does not delete or rewrite rollout files. It only changes a copied frontend bundle.

## Suggested upstream fix

It would be helpful if Codex Desktop allowed users to configure the local session/sidebar history limit, or if the sidebar automatically paginated far enough to populate project folders reliably.

At minimum, the UI should distinguish:

- "This folder has no conversations"
- "The conversation list has not been fully loaded"

For users with large local histories, a configurable cap such as 50 / 100 / 500 / 1000 / all would make the behavior predictable and remove the need for local patching.
