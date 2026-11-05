# Project instructions

These defaults consolidate recurring user instructions from this project's T3 Code history. The current task's explicit instructions take precedence. Apply them to the checkout you are working in; history may describe features that have not reached that checkout.

## Implementation and review

- For substantial implementation, use GPT-6.1 Sol subagents where useful, with clearly separated ownership. Medium is the historical default; use a different effort when the user requests it. Small, straightforward changes can be done directly.
- After substantive code changes, request an independent **Muse Wonder Full** review before the final handoff. Use the available Muse provider/model through T3 Code delegation; discover the current identifier rather than assuming one.
- Give the reviewer the intended behavior, final diff, validation results, and known limitations. Ask about correctness, regressions, missed edge cases, persistence, privacy, and UI behavior where relevant.
- Address actionable findings, rerun affected checks, and request a fresh Muse review of the updated result. Continue until Muse gives the go-ahead. Material changes after approval need another review.
- When the task authorizes commit/push/PR creation, obtain the review go-ahead before those actions. If Muse is unavailable, report the blocker and do not silently substitute another reviewer or claim approval.
- Reproduce reported bugs before treating a suspected code path as the cause. Distinguish observed failures from unverified review hypotheses, and validate each proposed fix against evidence.

## UI changes and screenshots

- Provide screenshots in the completion reply for every UI change, captured from the running app and inspected for layout and correctness. Include before/after images when changing an existing screen; capture the baseline before editing when practical.
- Summarize each changed feature alongside its screenshots. Exercise the actual interaction and relevant loading, empty, error, and populated states, rather than relying on a static mockup.
- Add or update meaningful UI tests for new user-facing functionality. Check small screens, light/dark appearance, large Dynamic Type, keyboard access, and accessibility as relevant to the change.
- **Do not commit screenshots or change-review images to source control.** They are review/validation artifacts. Store new captures outside the repository, such as a task-specific temporary directory, and attach them to the reply. Do not remove intentional product assets under this rule.
- If screenshots cannot be captured, explain the concrete limitation and what remains unverified. Do not present mockups or fixture-only tests as proof of production behavior.
- Prefer native SwiftUI controls and platform styling. Follow the existing visual system; recurring design feedback favors compact vertical spacing, useful horizontal space, and more room for workout/chat content. Apply Liquid Glass where supported, with deployment-target-compatible fallbacks.
- Use the T3 Code device tools for simulator/device interaction and screenshots when available, following their current instructions. Give concurrent UI test runners separate simulators.

## PR follow-through

- Read and individually assess all PR review comments, including CodeRabbit and Greptile. Fix valid findings and explain evidence for any disputed finding; do not mechanically apply suggestions.
- When asked to address comments and push, complete the fixes, relevant validation, and push rather than stopping at a plan.
- When explicitly asked to monitor until a 5/5 score or no further comments, continue the review/fix cycle to that requested condition using T3 Code's PR watch mechanism. Report a blocker if that condition cannot be reached.
- Resolve base-branch conflicts while preserving both sides' intent and verify the project builds before pushing.
- Historical requests to merge, push, delete branches, or deploy apply to their tasks; this file alone does not authorize those actions for every future task.

## Swift/iOS practices

- Keep workout rules, validation, serialization, and persistence in the Foundation-based `LiftLog/Core` package. SwiftUI views own presentation, navigation, and temporary form state; app/platform adapters own HealthKit, authentication, audio, and Live Activities.
- Group related models and services by domain in focused files. Avoid growing a catch-all models file or embedding business rules in view bodies.
- Keep UI-observable mutations on the main actor. Move expensive I/O, Health queries, parsing, and aggregation off the UI thread; use structured concurrency and explicit cancellation/lifetime ownership.
- Preserve in-progress assistant work across tab changes. Treat app backgrounding and platform execution limits explicitly; surface interrupted work honestly.
- Validate input at mutation boundaries. Preserve stable identities, original units, historical snapshots, and transactional rollback on failed saves. Test migrations and relaunch persistence when storage changes.
- Prefer supported package-manager dependencies over copying an entire upstream codebase. Preserve licenses and attribution. Use publicly available open-source exercise data; the user's selected source is `free-exercise-db`.
- `project.yml` is the XcodeGen source of truth. Regenerate `LiftLog.xcodeproj` after configuration changes and keep required generated project changes consistent with it.
- Preserve deployment-target compatibility, signing/capabilities, extension identifiers, and required Info.plist purpose strings. Local builds do not establish Xcode Cloud/TestFlight success.

## Product invariants

- Keep workout logging local-first and usable without an account or network connection. Optional iCloud Drive backups must not make local saves depend on cloud availability.
- Planned target reps/weights and performed reps/weights are distinct. Propagate workout edits only to remaining sets; never silently rewrite completed sets. Renaming a template must not create a new version.
- Health data is read-only and explicitly opt-in. Ordinary assistant workout tags must not implicitly include Health data. Preserve the documented per-request consent, scope, and persistence exclusions.
- Assistant mutations require user review/apply semantics, stale-data protection, and atomic validation. Keep credentials in protected storage and out of logs and fixtures.
- When adding another AI provider, aim for parity in user workflows while making actual platform limitations visible. Test generated claims against recorded facts; successful generation alone does not establish correctness.

## Validation and handoff

- Consult `docs/TESTING.md`, `docs/ARCHITECTURE.md`, and the relevant feature documentation. Verify older statements against the current source instead of copying stale test counts or feature inventories.
- Run `swift test` for core changes. For app/UI/platform changes, also build the iOS target and run the affected UI flows. Typical build commands:

  ```sh
  xcodegen generate
  xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  ```

- Run `python3 scripts/generate_exercise_catalog.py --check` when changing the bundled catalog or its generator. Run UI suites serially on an available isolated simulator, using the commands in `docs/TESTING.md`.
- Use isolated test storage and synthetic credentials/Health data. Do not reset a user's installation to make a test pass.
- Update relevant documentation with behavior changes. When executing an implementation plan, mark what is implemented and what remains.
- The final reply should state the outcome, checks and results, Muse review status, and material limitations; include screenshots for UI work. Separate mocked/simulator evidence from live-service and physical-device verification.

## History provenance

Derived from user messages across the project's T3 Code history, including these representative instructions:

- Muse review/fix loop: <t3-thread://v2/8d1be5df-e97b-4b2b-8b93-ed4be5c3afcb/18eb207a-e75a-424c-beb3-f9dc64ee9fee>
- UI tests and before/after reports: <t3-thread://v2/8d1be5df-e97b-4b2b-8b93-ed4be5c3afcb/7857cd67-5cf5-4460-b095-200029856cc6>
- Swift/iOS guidance and UI screenshots: <t3-thread://v2/8d1be5df-e97b-4b2b-8b93-ed4be5c3afcb/638afe95-8f3f-452d-bbd7-49f288c66f8f>
- Do not commit review screenshots: <t3-thread://v2/8d1be5df-e97b-4b2b-8b93-ed4be5c3afcb/010c4e6a-a217-48f0-952e-b914e3875b10>
- Reproduce suspected bugs before fixing: <t3-thread://v2/8d1be5df-e97b-4b2b-8b93-ed4be5c3afcb/d2522b5c-f1b5-41b7-9a45-daff19d6800f>
