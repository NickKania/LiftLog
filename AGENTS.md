# Agent guidance

These instructions apply to the entire repository. Read the relevant existing code and documentation before changing behavior, and preserve unrelated work already present in the checkout.

## Project context

Lift Log is a local-first SwiftUI iPhone app targeting iOS 17 and later. Templates, workout logging, and history must remain usable offline and without an account.

- `LiftLog/Core`: Foundation-based models, validation, analytics, persistence, and assistant logic. These sources also compile as the `LiftLogCore` Swift package; keep SwiftUI, UIKit, and platform-only services out of this layer.
- `LiftLog/App`: app lifecycle, dependency composition, and iOS integrations such as HealthKit, Keychain, notifications, and ActivityKit.
- `LiftLog/Views`: SwiftUI screens and reusable UI components.
- `LiftLog/Shared` and `LiftLogWidgets`: shared Live Activity payloads and widget presentation.
- `Tests/LiftLogCoreTests` and `Tests/LiftLogUITests`: core regression tests and native UI tests.
- `project.yml`: source of truth for the XcodeGen project. Change it rather than hand-editing generated project settings, then regenerate and include the corresponding project changes.

Consult [architecture](docs/ARCHITECTURE.md), [testing](docs/TESTING.md), and [workflow coverage](docs/WORKFLOWS.md). Read the storage, import, catalog, or assistant documentation when touching those features. Update relevant documentation when behavior or architecture changes.

## Swift and architecture

- Follow existing naming and formatting. Use clear Swift API names, explicit access control at module boundaries, and small types/functions with one coherent responsibility.
- Prefer structs and enums for value models and explicit state. Use stable domain IDs for collections and navigation; do not use array positions or newly generated UUIDs as view identity.
- Keep business rules and validation in the core/store rather than duplicating them in views. Reuse existing services and components before introducing abstractions or dependencies.
- Handle expected failures with throwing APIs or explicit results and actionable user feedback. Avoid force unwraps, `try!`, and silently discarded errors in production paths. Document deliberate best-effort cleanup.
- Preserve deployment compatibility. Guard newer APIs with availability checks and a working fallback; do not raise the deployment target or change Swift language mode as an incidental fix.
- Prefer dependency injection for external services, clocks, identifiers, and storage when deterministic testing requires it. Avoid new global mutable state and unnecessary singleton services.

## Concurrency and lifecycle

- Keep observable UI state and its mutations on `@MainActor`, following the existing `@Observable` stores. Give SwiftUI state a clear owner and use environment injection for shared stores.
- Use structured concurrency and `async`/`await`. Keep expensive parsing, network requests, file coordination, and substantial database work off the main actor where practical; preserve existing transactional ordering when refactoring.
- Tie asynchronous work to its owning screen or service, propagate cancellation, and reject stale results after navigation, selection changes, account changes, or deletion.
- Respect actor isolation and `Sendable` boundaries. Do not silence concurrency diagnostics with `@unchecked Sendable` or detached tasks without a documented safety argument.
- Avoid work with side effects inside SwiftUI `body`. Use lifecycle hooks and explicit user actions, and prevent repeated rendering from starting duplicate requests or writes.
- Derive timers from persisted dates/deadlines rather than assuming foreground ticks are reliable. Check background/foreground transitions and relaunch recovery for lifecycle-sensitive changes.

## SwiftUI and iOS UX

- Use native navigation, controls, sheets, alerts, and system materials where appropriate. Keep views focused and extract components when they express reusable behavior or make a complex screen easier to understand.
- Support Dynamic Type, light/dark appearance, safe areas, keyboard presentation, and smaller supported iPhone screens. Avoid rigid text heights and layouts that clip at accessibility sizes.
- Provide meaningful VoiceOver labels, values, and hints for custom controls. Hide decorative elements from accessibility, preserve logical reading order, and provide comfortable touch targets (generally at least 44 × 44 points).
- Do not convey meaning through color alone. Use sufficient contrast and labels or symbols alongside colors; respect Reduce Motion for custom animations.
- Keep transient drafts separate from committed records. Cancel must discard drafts; destructive actions must clearly identify their effect and use the existing confirmation patterns.
- Show appropriate loading, empty, unavailable, and error states. Keep logging responsive during optional assistant, Health, or backup operations.
- Use locale-aware formatting and the existing weight-unit conversion and input-validation helpers. Use calendar-aware date calculations instead of fixed-second assumptions for calendar days.
- Use stable accessibility identifiers for UI automation. Test user-visible outcomes rather than relying on incidental view hierarchy details.

## Persistence, security, and privacy

- Preserve stable identities, immutable template versions, independent workout snapshots, recorded units, and completed history. Do not rewrite historical records as a side effect of editing a template or display preference.
- Validate before saving, commit related changes atomically, and publish in-memory state only after successful persistence. Keep migrations backward-compatible and transactional; never replace unreadable user data with an empty store.
- Use bound SQLite parameters. Test schema upgrades, failed writes, restore behavior, and legacy decoding when changing storage. Follow [storage guidance](docs/STORAGE.md).
- Store credentials in the existing Keychain integration. Never commit tokens, local signing settings, provisioning material, personal databases, Health readings, or exported conversations. Redact sensitive values from logs and review artifacts.
- Preserve explicit Health consent and the existing read-only integration. Missing readings remain unavailable, not fabricated zeros. Health data must not leak into persisted chats, automatic titles, later requests, or backups; follow [assistant privacy boundaries](docs/CHATGPT_ASSISTANT.md).
- Keep optional network/cloud features independent of local saves. Handle cancellation, offline operation, permission denial, and partial failures without losing user data.

## Verification

Run checks appropriate to the change and report their actual results. Documentation-only changes need a diff review, not an app build.

For core behavior changes, add or update focused regression tests and run:

```sh
swift test
```

For app, widget, or project changes, build the iOS target:

```sh
# Run when project.yml or project structure changes:
xcodegen generate
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For changed UI flows, run the relevant native UI tests and exercise the screen interactively. Choose an installed simulator from `xcrun simctl list devices available`; do not assume a specific device name or OS is installed. Run UI tests serially on an isolated simulator because their fixture data is shared:

```sh
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -only-testing:LiftLogUITests/<RelevantTestClass> test
```

Use existing DEBUG-only synthetic fixtures and test launch arguments described in `docs/TESTING.md`. Do not reset personal app data or use live credentials for automated tests. Run `python3 scripts/generate_exercise_catalog.py --check` when changing catalog data or generation. Identify physical-device checks still needed for signing, real HealthKit data/permissions, iCloud, or Live Activities; simulator results do not establish those behaviors.

## Required screenshots for UI changes

**Every change affecting visible UI must include screenshots in the completion reply for user review.** This includes layout, styling, text, navigation, charts, sheets, and widget/Live Activity presentation.

Screenshots and other images captured to review or validate changes are review artifacts only; never commit them to source control.

1. Build and run the changed app or extension on an iOS simulator or device. Navigate to the affected screen with synthetic, representative data and capture the final implementation. Mockups and SwiftUI previews do not substitute for running-app evidence.
2. Capture each materially changed screen and relevant states (for example an expanded editor, validation error, empty state, or presented sheet). For appearance/layout changes, include light and dark mode; for text/layout changes, include an accessibility Dynamic Type size. Check a smaller supported iPhone size when space constraints matter.
3. Inspect the screenshots before finishing. Fix clipped text, overlaps, obscured controls, incorrect safe areas, poor contrast, and unintended changes, then recapture after the final edit.
4. Save PNG artifacts in an accessible location such as the ignored `artifacts/screenshots/<feature>/` directory or an external artifact directory. Use descriptive filenames indicating the screen and configuration. Keep personal data, credentials, and unrelated screens out of captures.
5. Embed or attach the screenshots in the final reply so the user can review them directly. In T3 Code, Markdown images with absolute file paths are supported: `![Screen — dark mode, large text](/absolute/path/to/screenshot.png)`. Label the state and report the device/OS used, checks run, and any remaining verification gaps. A screenshot buried only in an `.xcresult` bundle is insufficient; export and attach it.

Prefer the available T3 device tools to open the simulator/device for the user and capture screenshots. A terminal fallback for an already selected simulator is `xcrun simctl io <SIMULATOR_UDID> screenshot <OUTPUT_PATH>.png`; use an explicit UDID to avoid capturing the wrong device.

If building, running, or capturing is blocked, state the exact blocker and which screenshots are missing. Do not claim UI verification is complete or substitute fabricated images. No screenshot is required for changes that do not affect UI.
