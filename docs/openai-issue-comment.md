I hit what looks like the same sidebar/project-listing class of bug, but on a larger local history.

Observed on Windows Codex Desktop with hundreds of local sessions:

- `state_5.sqlite` still had 443 threads, 436 active.
- `.codex/sessions/.../rollout-*.jsonl` files still existed.
- Specific project folders such as older local workspaces appeared empty in the sidebar.
- Direct `codex.exe app-server` probing showed `thread/list` supports `nextCursor` pagination and returns more data across pages.
- The frontend state snapshot before patching showed far fewer recent threads loaded than existed in local history.

This made the problem look like data loss, but the sessions were still on disk and still addressable by app-server. The failure was in the recent-thread/sidebar loading path.

I documented a local Windows-only workaround here:

https://github.com/constansino/codex-desktop-session-limit-patch

The workaround does not mutate `.codex/state_5.sqlite`, does not reorder `updated_at`, and does not rewrite rollout files. It keeps the official WindowsApps install untouched, copies the app resources into a separate local directory, and patches the copied frontend bundle so the initial recent-thread load follows `nextCursor` for multiple pages. It also raises load-more/search page sizes and gives the patched window a separate title/userData path so it can coexist with the official app.

I think the upstream fix should be one of:

- Auto-page the sidebar's recent-thread load until enough data is available for project grouping.
- Add a user-configurable local sidebar/session history cap, for example 50 / 100 / 500 / 1000 / all.
- Show a different UI state for "the list is not fully loaded yet" instead of making a folder look like it has no conversations.

This would avoid local repacking and make the behavior predictable for users with large local histories.
