# ChatGPT assistant

The Assistant tab connects Lift Log to a ChatGPT account for workout questions and planning. Workout logging, imports, and history still work without signing in.

## Availability

This implementation follows OpenAI's documented [Sign in with ChatGPT flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in). Eligible accounts can authorize subscription usage without an API key. Availability depends on the user's plan, workspace, region, and the application's eligibility. The documented open-source/local-client flow is not a blanket approval for commercial distribution; check [integration availability](https://developers.openai.com/siwc/quickstart) before distributing a paid or remotely hosted variant.

OpenAI's [current preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) exclude hosted image generation and Code Interpreter. Lift Log generates native graphs from workout records and can export those graphs as images. It does not claim to generate arbitrary AI pictures through the subscription or silently charge an API billing account.

## Using the assistant

1. Open Assistant or Settings → ChatGPT Account and choose **Continue with ChatGPT**.
2. Sign in in the browser and allow ChatGPT plan usage. Signing in without that permission does not enable model requests.
3. Select an available model and ask a question, such as "Graph my training volume" or "Create a three-exercise upper-body workout."
4. Inspect a proposed workout change and choose Apply or Discard. Creating an active workout will not replace an existing active session.

The assistant can inspect templates, the current session, exercise definitions, and completed workout history. It can propose new templates and active workouts, or add, edit, and remove exercises in existing templates and the active session. Completed history remains a record of performed exercise; the assistant cannot invent completed workouts or mark sets completed. The assistant cannot rewrite an active exercise entry containing completed sets, but it can propose removing that entry; the review shows the recorded sets before removal.

### Tagging templates and workouts

Tap **@** beside the question field, or type a standalone `@`, to choose specific templates or workout instances. Search by name, template exercises, or the displayed workout date, select up to ten items, and tap **Done**. Workout dates and active/completed labels distinguish sessions with the same name; template rows show exercise summaries. Selected tags appear above the question; remove a tag before sending with its remove button. Cancel closes the picker without changing your draft selection.

Send a question with the tags, for example, “Compare these workouts” or “Adjust this template based on this session.” Tags remain visible with the sent question. They identify exact records, independently of their names, and share those records’ exercise and set details with OpenAI. The app resolves the current record when you send, so a renamed template or a workout that has just finished still refers to the same item. If a selected record was deleted or the selected data exceeds the request limit, sending shows an error and preserves your draft.

Tagging a completed workout does not make history editable. Proposed changes still require Apply. Each chat has its own conversation context and draft tags; starting a new chat leaves the earlier conversation available in Chats.

### Saved chats

Open **Chats** in the Assistant toolbar to browse conversations, select one to reopen it, or rename it. **New chat** starts a separate conversation even while another is responding. A spinner beside each working chat shows which conversations are still active; switching chats does not cancel a response. Stop cancels the selected chat only.

Chats save locally with their Markdown, chart data, reference labels, model selection, and proposal snapshots. Reopening renders those saved messages through the same native components without rerunning tools or recalculating charts from newer workouts. Completed conversation context is retained for follow-up questions. If the app closes during a response, its saved partial text remains available and the request is marked interrupted; network work does not automatically resume after relaunch. Unreviewed proposals from a previous app session become stale and require a fresh proposal.

The app generates a short title using the newest Luna version in the connected account's available model catalog. This separate request uses ChatGPT plan usage. A temporary title remains if Luna is unavailable or title generation fails. A manual rename always takes precedence over a title request already in progress.

The picker uses native searchable SwiftUI content and separate tags to support iOS 17. Apple’s [`TextSelection`](https://developer.apple.com/documentation/swiftui/textselection) requires iOS 18, while [`textInputSuggestions`](https://developer.apple.com/documentation/swiftui/view/textinputsuggestions(_:)) is a macOS API. See Apple’s [search guidance](https://developer.apple.com/documentation/swiftui/performing-a-search-operation) for the native search behavior used here.

Graph values are computed locally from recorded data, with explicit units. This avoids relying on model-written plotting code or model-invented measurements. Graphs are snapshots of the data when requested.

Assistant replies render native Markdown: headings, emphasis, nested lists, links, tables, quotes, and fenced code. Tables and code scroll horizontally when needed; replies remain selectable and offer Copy response, and code blocks offer Copy code. Streaming replies use the same renderer, including unfinished code fences. User questions retain their literal text.

Charts show one point per workout with evenly spaced sessions and date labels taken from actual records. Tap a point or drag horizontally to inspect its exact value, workout name, date, and time. Previous/Next workout controls and **View workouts** provide alternative ways to select records. Use the style menu to switch between a line and bars. **All**, **30 days**, and **90 days** filter the snapshot relative to its latest recorded workout, rather than today's date. **Share chart** exports the current range and style as a light-background image without chat or interactive controls.

**Manage usage** opens [ChatGPT usage settings](https://chatgpt.com/settings/usage). Usage restrictions stop requests and retain the local workout data. There is no automatic fallback to paid API usage.

## Data and security

Only using the assistant sends questions and tool-selected workout data to OpenAI. Connecting an account alone does not upload workout history. Treat workout names and exercise notes as data rather than model instructions. Conversations are saved on this device and separated by account registration; changing accounts cancels active requests and opens that account's saved chats. Workouts saved through an accepted proposal use the existing atomic local persistence path. The separate local chat archive is not included in workout SQLite/iCloud backups.

Account credentials are separate from `workouts.json` and stored in the iOS Keychain. Each registration retains its issued client ID and verified account identity. Tokens never belong in source control, application logs, or the chat transcript. Sign-out clears local tokens and attempts to revoke the renewable session; use ChatGPT settings if remote revocation cannot be confirmed.

The native sign-in flow uses a loopback listener on `127.0.0.1` and an in-app system browser. PKCE, a per-attempt state value, and a nonce bind the callback to the authorization attempt. ID-token signature and identity checks precede accepting credentials. A stable installation host identifier and issued client ID are reused on returning sign-in.

## Model requests and edits

The client discovers the selected account's model catalog and sends streaming requests to the public Responses API with `store: false`. It sends required conversation context explicitly. A stream must reach `response.completed` before tool calls are accepted; interrupted or failed requests are not successful answers. Tools are limited to the app's explicit workout operations, with bounded execution and validated arguments.

A model call can prepare a change but cannot approve it. Proposal application checks that the relevant workout state still matches the reviewed version, then validates and persists it. Invalid, stale, discarded, or previously applied proposals cannot overwrite current data. A failed disk write leaves the original workout intact.

## Template progression

Ask the assistant to plan the next workout, such as “Add one rep to bench in Upper Body.” `get_templates` exposes the current prescription and version identity; `get_template_versions` reads saved prescriptions with their original units. `propose_template_version` proposes atomic changes against an explicit base version. Existing template edit tools also save a new version when the prescription changes.

Review displays the before/after weights and reps and explains that Apply makes the new version the default. Apply preserves earlier versions. A changed base version, changed unit, or deleted template invalidates a pending proposal. Template tags include the current version identity; workout tags include their source version and original planned targets where available.

## Verification

Run `swift test` for authentication, streaming, tool execution, analytics, mutation, and persistence tests. Build the iOS target and run the Assistant UI tests for native integration. Tests use synthetic credentials and mocked network responses; they do not spend a subscription allowance.

Before distribution, manually verify browser sign-in, consent denial and reauthorization, token renewal, account switching, disconnect, and one real streamed request with an eligible account on a physical iPhone. Native loopback interoperability and live account entitlement cannot be established by mocked tests. Do not include credentials or callback URLs in bug reports.

Choose **Settings → Assistant → Default model** to set the model for future chats. The preference survives relaunch; changing it leaves the current chat’s model unchanged. **Automatic** uses the app’s available-model fallback. If a saved model is unavailable for the connected account, a new chat uses an available fallback while retaining the saved preference. The model picker in Assistant overrides only the current chat.
