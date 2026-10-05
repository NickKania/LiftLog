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

Graph values are computed locally from recorded data, with explicit units. This avoids relying on model-written plotting code or model-invented measurements. Graphs are snapshots of the data when requested.

**Manage usage** opens [ChatGPT usage settings](https://chatgpt.com/settings/usage). Usage restrictions stop requests and retain the local workout data. There is no automatic fallback to paid API usage.

## Data and security

Only using the assistant sends questions and tool-selected workout data to OpenAI. Connecting an account alone does not upload workout history. Treat workout names and exercise notes as data rather than model instructions. Conversations and pending proposals are transient; resetting a conversation or changing the selected connection clears them. Workouts saved through an accepted proposal use the existing atomic local persistence path.

Account credentials are separate from `workouts.json` and stored in the iOS Keychain. Each registration retains its issued client ID and verified account identity. Tokens never belong in source control, application logs, or the chat transcript. Sign-out clears local tokens and attempts to revoke the renewable session; use ChatGPT settings if remote revocation cannot be confirmed.

The native sign-in flow uses a loopback listener on `127.0.0.1` and an in-app system browser. PKCE, a per-attempt state value, and a nonce bind the callback to the authorization attempt. ID-token signature and identity checks precede accepting credentials. A stable installation host identifier and issued client ID are reused on returning sign-in.

## Model requests and edits

The client discovers the selected account's model catalog and sends streaming requests to the public Responses API with `store: false`. It sends required conversation context explicitly. A stream must reach `response.completed` before tool calls are accepted; interrupted or failed requests are not successful answers. Tools are limited to the app's explicit workout operations, with bounded execution and validated arguments.

A model call can prepare a change but cannot approve it. Proposal application checks that the relevant workout state still matches the reviewed version, then validates and persists it. Invalid, stale, discarded, or previously applied proposals cannot overwrite current data. A failed disk write leaves the original workout intact.

## Verification

Run `swift test` for authentication, streaming, tool execution, analytics, mutation, and persistence tests. Build the iOS target and run the Assistant UI tests for native integration. Tests use synthetic credentials and mocked network responses; they do not spend a subscription allowance.

Before distribution, manually verify browser sign-in, consent denial and reauthorization, token renewal, account switching, disconnect, and one real streamed request with an eligible account on a physical iPhone. Native loopback interoperability and live account entitlement cannot be established by mocked tests. Do not include credentials or callback URLs in bug reports.
