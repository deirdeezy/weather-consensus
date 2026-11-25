# Xcode 27 reference for this project

Checked 24 Nov 2026 against Apple's documentation and release notes (sources at the bottom). Installed on the main development Mac: Xcode 27.2 (Swift 6.4, iOS 27.2 SDK), iOS platform only. Re-check this file when Xcode updates; do not rely on memory.

## 1. Connect Claude Code to Xcode (MCP)
- Owner setting (done at install): Xcode › Settings › Intelligence › Model Context Protocol › "Allow External Agents to Use Xcode Tools" (Always, While Xcode is Open, or Never).
- Register Xcode's MCP server for Claude Code (Apple's command):
  `claude mcp add --transport stdio xcode -- xcrun mcpbridge`
  Verify with `claude mcp list`. If the `claude` command is not installed (the desktop app does not need it), use a project `.mcp.json` with server `xcode`, type `stdio`, command `xcrun`, args `["mcpbridge"]`, and ask the owner to approve it.
- Do this at the start of Stage 3 (no Xcode project exists before then).
- This repo uses the project `.mcp.json` route (the desktop app has no `claude` command). Approve the `xcode` server when Claude Code asks; its tools appear in the next session.
- Xcode 27.2's bridge also offers `XcodeNewProject` and `XcodeNewTarget`; use them for new targets (widgets, notification extensions). From the command line, `xcodebuild -convert-project "Xcode Project" -project X.xcodeproj` converts an older project to the JSON format.
- Open the project in Xcode before using Xcode tools. Xcode alerts the owner when an agent connects and while it is active.
- Preview feature (since Xcode 27 beta 5): `sudo xcrun mcp-server enable` runs the MCP server without an open workspace (`xcrun mcp-server status` to check). Early preview; may need an Xcode relaunch or reboot. Ask the owner first. Never use `--unsafe-always-allow-all-agents` (Apple: not recommended at a desk).

## 2. Xcode tools to use (prefer these over guessing or hand-editing)
- Build and test, with live status.
- RenderPreview / Preview Snapshot: render any `#Preview`, including variants (light/dark, portrait/landscape, type sizes), widget timelines and Live Activity states; choose the render destination; returns the simulator platform, device and OS, plus the preview's name and line.
- Simulators: boot, install and launch the app, synthesize touches, take screenshots. Use these to check UI work yourself before reporting it done.
- Debugging: control the run state, read and use the debugger console.
- Project settings: list and switch schemes and run destinations; read and change build settings, compiler flags, entitlements and Info.plist keys. Use these for push notifications and CloudKit capabilities instead of hand-editing files.
- String Catalogs: read, plan and edit translations; "Prepare Project for Localization".
- Insights: crashes, hangs, energy, disk writes and launch issues from shipped builds.
- Apple developer documentation search (natural language). Use it before writing code against any Apple API.

## 3. Project setup rules
- Project format: new projects in Xcode 27.2+ use the JSON configuration file (`.xcproj` inside `.xcodeproj`). It is open source, smaller, merge-friendly and meant for agents to edit. Keep it. It only opens in Xcode 27 or later (fine: every Mac used for this project runs Xcode 27). To convert an older project: Project navigator › select project › File inspector › Project Format › JSON.
- Location: `ios/` in this repo. SwiftUI App life cycle (with the iOS 27 SDK, apps without the scene-based life cycle fail to launch).
- Swift 6.4. `@State` is now a macro. Use Swift concurrency checking as the default template sets it.
- Minimum iOS version: **iOS 27.0** (deployment target `IPHONEOS_DEPLOYMENT_TARGET = 27.0`; owner decision, 25 Nov 2026). iOS 27 runs on the same iPhones as iOS 26 (iPhone 11 and later, SE 2nd and 3rd generation), so no phone is locked out; we build and test against one OS with no availability checks; lowering it later is easy, raising it after release is not. Full reasoning and numbers: `docs/BUILD_PLAN.md`, Stage 3. Sources: https://support.apple.com/en-us/guide/iphone/iphe3fa5df43/ios, https://developer.apple.com/support/app-store/, https://developer.apple.com/news/upcoming-requirements/
- Xcode 27 runs only on Apple silicon Macs.

## 4. Previews
- Use `#Preview`. `PreviewProvider` is deprecated.
- `#Preview(arguments:)` shows a grid, one preview per argument. Use it for the living sky (every time of day x every weather) and the Certainty tiers.
- iOS previews have a Resizable Canvas mode (use it for iPhone Duo sizes), localization previews, and contrast and control-border overrides.

## 5. Devices and iPhone Duo
- Device Hub runs simulators and real devices in one window. Pair an iPhone over the network (iOS 27+): Device Hub sidebar › + › Pair Nearby Device… Simulators can simulate memory pressure, shake and slow animations.
- iPhone Duo (foldable, on sale since Oct 2026): apps built with the iOS 27 SDK resize between the compact outer display and the large inner display.
  - Lay out with size classes, never device idiom or interface orientation.
  - Folding or unfolding is a size-class and trait change, not a relaunch: keep navigation and scroll state.
  - TabView: consider `.defaultTabBarPlacement(.sidebar)` on the inner display. Bars may move to the side on the outer display; follow the system.
  - Outer display landscape ("tent") is worth supporting for a weather app.
  - Test in the iPhone Duo simulator. Known issue: Duo screenshots may be black for a few minutes after booting.

## 6. Testing
- Swift Testing for new tests.
- Launch-test template runs across every orientation, localization and appearance the app supports.
- `XCUIVoiceOverService` checks VoiceOver focus and speech in UI tests (Certainty ring and dots need good labels).
- Test plans can set how app crashes during UI tests are treated (off, warning, failure, fatal failure).
- `swift test --maximum-repetitions N --repeat-until fail` to hunt flaky tests.

## 7. App icon
- Icon Composer 2.0: sharper rendering for the 2027 OS releases (refractivity, outside specular, deeper shadows). Preview both design generations in its toolbar; one icon file serves every OS version. Build the three-circle icon from the design canvas here.

## 8. Localization
- Put all user-facing text in a String Catalog from day one. Agents can translate it later (Generate Translations). Mark strings that must stay as-is with the comment "do not translate".

## 9. Distribution
- App Store: since 28 Apr 2026, uploads must be built with Xcode 26 or later and the iOS 26 SDK or later. Xcode 27 meets this. Check Apple's Upcoming Requirements page before each release.
- TestFlight, push notifications and CloudKit need the paid Apple Developer Program. Xcode Cloud can now build and test without it and has a TestFlight workflow; not part of our plan (backend CI is GitHub Actions; the app is built locally).

## 10. Agents inside Xcode (owner's option, not required)
- Claude Agent, Codex, Gemini and Antigravity can run inside Xcode (Settings › Intelligence › Agents › Get). Plan mode with `/plan` (exit with `/exit-plan`); plans are editable Markdown. Apple specialists for localization, UIKit resizing and accessibility. Plug-ins add skills, MCP servers and ACP agents. Optional filesystem security layer in Intelligence settings.
- Configuration for agents launched inside Xcode lives in `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig` (Claude Agent) and affects only those agents. This repo's CLAUDE.md and docs stay the source of truth; point any in-Xcode agent at them.

## Sources
- Xcode updates: https://developer.apple.com/documentation/updates/xcode
- Xcode 27 release notes: https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- Xcode 27.2 release notes: https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes
- Giving external agents access to Xcode: https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode
- Setting up coding intelligence: https://developer.apple.com/documentation/xcode/setting-up-coding-intelligence
- Extending and customizing agents: https://developer.apple.com/documentation/xcode/extending-and-customizing-agents
- Project configuration file format: https://developer.apple.com/documentation/xcode/updating-your-xcode-project-configuration-file-format
- Platform updates (27 releases): https://developer.apple.com/documentation/updates
- iPhone Duo: https://developer.apple.com/iphone-duo/prepare/ and https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo
- SDK minimum requirements: https://developer.apple.com/news/upcoming-requirements/
