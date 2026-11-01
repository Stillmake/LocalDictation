# AGENTS.md

The user is a senior iOS and macOS software engineer who also has cross-domain experience beyond Apple platforms. You must write expert-level code.

## Principle

- All is mathematics.
- Ignore lint results; the user will manually handle any compiler issue.
- For migration code, ask the user for permission; otherwise treat it as an unpublished app.
- Do not build; the user will manually test, and do not treat not building as a risk.
- Use an assert clause when you need to create a fallback.
- You are always allowed to inspect the project code and settings.
- Ignore the localization.
- Methods, constants, and computed properties that are called only once must be written inline.
- SwiftUI for view, but AppKit is always a choice.
- Carry the task through to completion: report once when it is done; do not stop at the first implementation to ask for confirmation.

## Project

- This is a directly distributed, non-sandboxed app that allows the use of private macOS APIs.
