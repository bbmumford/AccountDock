# The Universal Modern macOS App Playbook

This document is a comprehensive master guide for bootstrapping, architecting, and deploying modern native macOS applications. Extracted from best practices and production-ready deployments (like AccountDock), it serves as a universal blueprint for both lightweight Menubar utilities and full-featured desktop applications.

---

## 1. Project Management: The "Single Source of Truth"

Never manually create or modify an Xcode project file (`.xcodeproj`). It inevitably leads to Git merge conflicts, broken configurations, and fragile team collaboration.

- **The Tool**: Use [XcodeGen](https://github.com/yonaskolb/XcodeGen) (or Tuist).
- **The Core Principle**: Define your entire project structure, targets, entitlements, and build settings in a declarative `project.yml` file at the root.
- **Info.plist Management**: Do **not** maintain a static, hardcoded `Info.plist` file. 
  - Let XcodeGen synthesize it dynamically by defining an `info.properties` block in your YAML.
  - Map dynamic variables like `$(MARKETING_VERSION)` directly from the YAML to ensure your App version and your Git tags are always synchronized.
- **Version Control**: Add `*.xcodeproj/` and `*.xcworkspace/` to your `.gitignore`. They are strictly ephemeral build artifacts.
- **The Workflow**: Anyone cloning the repo simply runs `xcodegen generate` to instantly build a pristine, localized Xcode environment.

## 2. App Archetypes & SwiftUI Lifecycle

Modern macOS apps should default to SwiftUI for the UI layer, dipping into `AppKit` (via `NSViewRepresentable` or `AppDelegate`) only when the framework falls short.

### Archetype A: The Standard Windowed App
- Use `WindowGroup { ContentView() }` as the primary scene.
- **Window Management**: Use SwiftUI window modifiers like `.defaultSize()`, `.windowResizability()`, and `.windowStyle(.hiddenTitleBar)` for modern, unified toolbar looks.

### Archetype B: The Menubar-Only Utility (Agent)
- Define `LSUIElement: true` in your `project.yml` properties. This prevents the app from showing up in the Dock or the Force Quit menu.
- Use `MenuBarExtra { ContentView() } label: { Image(systemName: "star") }`.
- **Style**: Use `.menuBarExtraStyle(.window)` for a modern, rounded popover, or `.menuBarExtraStyle(.menu)` for a traditional dropdown list.

### Archetype C: The Hybrid App (Menubar + Main Window)
- If your app lives in the menubar but needs to occasionally open a main dashboard window, you must manually manage the application activation policy.
- Switch `NSApp.setActivationPolicy(.regular)` when the window opens (to show in Dock), and `.accessory` when it closes.

### Common Components
- **Settings**: Utilize SwiftUI's native `Settings { SettingsView() }` scene. On macOS, this automatically hooks into the `Cmd + ,` shortcut and provides a standard Preferences window with native tab styles.
- **Launch at Login**: Use macOS 13+ `ServiceManagement.SMAppService.mainApp.register()`. Do not use the legacy and overly complex `SMLoginItemSetEnabled` helper-app pattern.
- **Deep Linking**: Define `CFBundleURLTypes` in your `project.yml`, and use `.onOpenURL { url in ... }` in your root SwiftUI view to intercept custom scheme invocations.

## 3. Sandboxing & Entitlements

Security configurations fundamentally alter what your app can do. You must define this early in `AccountDock.entitlements` and reference it in `project.yml`.

- **App Sandbox (`com.apple.security.app-sandbox`)**: 
  - **Mac App Store (MAS)**: Mandatory. You *must* sandbox your app.
  - **Direct Distribution**: Highly recommended, but optional. If your app needs broad disk access (e.g., reading `~/.ssh` or user-defined arbitrary paths without explicit open dialogs), you may need to **disable** the Sandbox.
- **Hardened Runtime (`com.apple.security.get-task-allow`)**: 
  - **Mandatory for Notarization** outside the App Store. Hardened runtime prevents code injection and memory tampering.
- **Capabilities**: If Sandboxed, explicitly request entitlements for network (`network.client`), camera, microphone, or specific folder access (e.g., Downloads/Documents).

## 4. State Management & Data Persistence

Choose the right persistence layer based on data sensitivity and complexity:

- **Preferences / UI State**: Use SwiftUI's `@AppStorage` (UserDefaults) strictly for non-sensitive, flat data (e.g., theme preference, refresh intervals, boolean toggles).
- **Sensitive Data (Tokens, API Keys, Passwords)**: **Never** write these to flat files. 
  - Use the macOS `Security` framework (Keychain). 
  - Because your app is code-signed, it becomes a "Trusted Application" for the Keychain items it creates. It can read/write them silently without prompting the user for their Mac password.
- **Complex Relational Data**: 
  - Default to **SwiftData** (macOS 14+). It provides a highly ergonomic, purely Swift-native interface over Core Data.
  - Use `@Model` for your data classes and `@Query` in your views for automatic reactivity.

## 5. Automation & CI/CD (GitHub Actions)

Never build production releases manually on your local machine. A local build includes local cache, dirty Git states, and provisioning profile complexities.

- **Runner**: AccountDock uses GitHub's `macos-15` runner.
- **Unsigned Test First**: Run the test job with `CODE_SIGNING_ALLOWED=NO`.
- **Signed Archive**: The tag-only release job imports Developer ID
  Application and Installer certificates into a temporary keychain, then asks
  `xcodebuild archive` to sign the app with Hardened Runtime enabled.

## 6. Packaging & Distribution

AccountDock is delivered as a signed Installer package so the user-reviewed
update command can verify and install it with native macOS tools.

### Direct Distribution (Outside App Store)
1. **Certificates**: Export Developer ID Application and Developer ID Installer
   `.p12` certificates and store them as base64 GitHub secrets.
2. **Package**: Build `AccountDock.pkg` with `pkgbuild --component`, signed by
   the Developer ID Installer identity.
3. **Notarization**: Submit the package with `xcrun notarytool submit --wait`.
4. **Stapling**: Staple the notarization ticket to the package and assess it
   with Gatekeeper before publication.
5. **GitHub Releases**: Tie CI to `v*` tags and attach a notarized Installer
   package plus its SHA-256 file. AccountDock uses `AccountDock.pkg` and
   `AccountDock.pkg.sha256`.

### Mac App Store (MAS) Distribution
- Requires a `Mac App Distribution` certificate and a specific Provisioning Profile.
- Generates a `.pkg` instead of a `.dmg`.
- Does **not** require manual Notarization (`notarytool`), as Apple performs this during the App Store Connect review process.

## 7. Safe user-driven updates

AccountDock deliberately does not self-modify or run privileged commands:

1. Query `https://api.github.com/repos/bbmumford/AccountDock/releases/latest`.
2. Compare the release tag with `CFBundleShortVersionString`.
3. Require both `AccountDock.pkg` and `AccountDock.pkg.sha256`.
4. Fetch and validate the digest before offering an update.
5. Display a copyable command which downloads to `mktemp`, verifies SHA-256,
   validates the Installer signature with `pkgutil`, asks Gatekeeper to assess
   it with `spctl`, and finally invokes Apple's `installer`.

The user can inspect the entire command before running it. Administrator
authorization remains an explicit macOS prompt. CI must Developer-ID sign,
notarize, and staple the package; an unsigned release is not accepted by the
generated command.

## 8. Aesthetics & Polish

A native macOS app must look and feel like it belongs on the system.

- **Iconography**: macOS icons (Big Sur and later) must be "Squircles" (Superellipses) with specific proportions. 
  - They should **not** fill the entire 1024x1024 canvas. 
  - Scale the core graphic to ~824x824, center it, and apply a soft drop shadow. 
- **Asset Catalogs**: Use automated scripts to generate all required resolutions (`16x16` up to `1024x1024` in `1x` and `2x` scales) and their corresponding `Contents.json` to form a valid `.appiconset`.
- **Translucency & Materials**: Liberally use `.background(.regularMaterial)` or `.ultraThinMaterial` in SwiftUI to get the native macOS frosted-glass blur effects that adapt to the user's desktop wallpaper and Dark Mode settings.

## 9. Observability & Agent-Driven Iteration

Modern software engineering heavily leverages AI Agents. To maximize an Agent's ability to autonomously fix bugs and optimize code, the app must have high observability.

- **Persistent File Logging**: Do not rely solely on Xcode's console `print()`. Implement a unified logging system (e.g., `FileLogger`) that writes structured logs (Info, Warning, Error, Debug) to a persistent local file (like `~/Library/Logs/MyApp.log`).
- **Performance & State Tracking**: Log critical lifecycle events, network request latencies, and state mutations. This provides the "breadcrumb trail" needed to diagnose complex state issues.
- **The Agent Feedback Loop**: 
  - When an AI Agent is tasked with modifying the app, it must follow an **Observe -> Act -> Validate** loop.
  - After injecting code modifications, the Agent MUST automatically trigger a local compilation (`xcodebuild`).
  - If tests exist, the Agent should run them. If not, the Agent should launch the built binary and use tools like `tail -f` or `grep` on the app's persistent log file to monitor the runtime behavior.
  - The Agent must autonomously scan these logs for crashes, performance bottlenecks, or unexpected `[Error]` outputs, and iteratively refine its own code until the logs reflect a healthy, stable execution.

## 10. Ecosystem & Third-Party Libraries

While avoiding unnecessary bloat is good, **do not reinvent the wheel for complex or core domains**. Writing everything from scratch increases the surface area for bugs, edge cases, and unexpected behaviors—especially when AI Agents are writing the code.

Embrace mature, battle-tested third-party libraries via Swift Package Manager (SPM):
- **Complex UI**: For highly interactive components (like syntax highlighters, advanced markdown renderers, or complex charts), use established community libraries instead of wrestling with raw `NSView` wrappers.
- **Databases**: For anything beyond simple UserDefaults or lightweight SwiftData, use **GRDB**, **Realm**, or raw **SQLite.swift**. These handle thread-safety, migrations, and concurrency far better than a hand-rolled JSON file manager.
- **Audio/Video & Media**: AVFoundation is notoriously complex and stateful. Use robust wrappers (like **AudioKit**) if doing complex media processing or recording.
- **Logging & Telemetry**: Instead of writing a custom `FileLogger`, consider mature libraries like **CocoaLumberjack** or **SwiftyBeaver** for automatic log rotation, archiving, and thread-safe file writing.

**Rule of Thumb for Agents**: When asked to implement a deeply complex feature (e.g., "add global keyboard shortcuts" or "implement an SQLite database"), an Agent should first suggest or utilize a well-known SPM library (like `HotKey` or `SQLite.swift`) rather than generating 1000 lines of fragile, low-level Swift code.

## 11. Advanced AI-Driven Workflows (TDD & Refactoring)

When collaborating with AI Agents (like Claude Code), the codebase must be structured to guide the AI safely and prevent it from introducing regressions.

- **Test-Driven Development (TDD) as a Safety Net**:
  - **Red-Green-Refactor**: When asking an Agent to fix a bug, instruct it to *first* write a failing test that reproduces the bug, and *then* implement the fix.
  - **Characterization Tests**: Before allowing an AI to perform a large-scale refactor, have it write tests to lock down the existing behavior (Refactor Guards).
- **Protocol-Based Abstractions**: AI Agents are much better at writing isolated, testable code when dependencies are abstracted. Define clear Protocols for Networking, Analytics, and Data Access layers so the AI can easily mock them during testing.
- **SwiftUI Debugging**: Instruct Agents to utilize `Self._printChanges()` inside SwiftUI views to autonomously diagnose unnecessary re-renders and performance hangs.

## 12. Apple Ecosystem Compliance & App Store Readiness

Even if you distribute directly, adhering to App Store standards ensures your app remains future-proof and behaves like a first-class citizen.

- **Privacy Manifests (`PrivacyInfo.xcprivacy`)**: Apple strictly enforces Privacy Manifests. Always declare the data your app collects and the "Required Reason APIs" (like File Timestamp APIs or User Defaults) your app uses.
- **Accessibility by Default**: Do not treat accessibility as an afterthought. Instruct your AI to implement VoiceOver support (`.accessibilityLabel`, `.accessibilityValue`) and Dynamic Type natively from day one.
- **HIG Compliance**: Applications should strictly follow the Human Interface Guidelines. For macOS, this means utilizing standard sidebars, native typography, and appropriate visual materials (like "Liquid Glass" translucent backgrounds).

---
*Maintained as the core standard for macOS engineering.*
