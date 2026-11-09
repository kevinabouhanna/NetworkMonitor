# Product

<!-- impeccable:product-schema 1 -->

<!-- Drafted for #437 from Kevin's brief and the repository, 2026-11-09. Waiting on
Kevin's review: anything marked (inferred) came from the code or docs, not from him. -->

## Platform

macos

A native macOS menu bar app (SwiftUI inside AppKit windows), macOS 13 or later, Apple
silicon and Intel. Impeccable has no macOS platform: its iOS reference (touch targets, tab
bars, Dynamic Type, the Simulator) doesn't apply. The macOS Human Interface Guidelines do.

## Users

- **People who want to see what their Mac talks to:** which apps use the connection,
  which companies and countries they reach, how much data went where. Most open a window,
  read it, and close it.
- **Some who tune blocking:** they block a company or an app, choose ad and tracker
  lists, write their own rules, and come back when a site breaks.
- (inferred) Often on a metered connection, such as a phone's hotspot, where knowing and
  limiting what's used matters.

## Product Purpose

Live network speed in the menu bar, which apps used the data, and a firewall to block
what they connect to. **Stats first, control second:** what happened comes before what to
change.

## Positioning

(inferred) Everything is named on the Mac itself: no account, no telemetry, nothing looked
up online. Its own network use is a monthly data file, a weekly list update and a daily
update check, all from GitHub, all switchable off. Free and open source (MIT).

## Operating Context

- The menu bar readout and its popover are the everyday surface; the windows are opened
  on purpose: Connections (⌘K), Ads and Trackers (⌘B), Usage History, Settings (⌘,).
- Several windows can be open at once beside other apps; the app never takes over the
  screen.
- (inferred) Glanced at, not lived in: a visit lasts seconds to a few minutes.

## Capabilities and Constraints

- Usage History by day, week, month or year; Connections by company, app or country, as
  a list, a map or both; Ads and Trackers' Overview, Log, Lists and Rules; Hotspot mode;
  a speed test; settings in panes.
- The content filter, the helper daemon and updates need a notarized Developer ID build
  in /Applications.
- Built with Command Line Tools only: no Xcode previews, and view state lives in
  `ObservableObject`s rather than `@State`.
- In English and, in progress, Chinese (#428, #429): every string is translated, and
  layouts hold longer or shorter text.
- A window's minimum width is what its toolbar needs; controls are never hidden in an
  overflow menu (#315).

## Brand Commitments

- **Plain words.** Features and settings are named without technical terms ("Enhanced ad
  blocking", not "HTTPS filtering"); how it works sits behind an ⓘ beside it.
- **The Mac's own look.** System controls, SF Symbols, system fonts and colours, light and
  dark both first-class.
- Never "ad" or "ads" in the website's file names, ids or labels (browser ad blockers hide
  them, #377). The app may say "Ads".

## Evidence on Hand

- The website (kevinabouhanna.github.io/NetworkMonitor), the README's demo and pictures,
  and `docs/`.
- No user research, analytics or testimonials exist (there is no telemetry); none may be
  invented.

## Product Principles

1. **Data before settings.** A window or pane opens on what happened; what to change is
   one step away, not in the way.
2. **Calm by default.** Quiet until something needs attention: no alarms for normal
   traffic, colour only where it means something (blocked, allowed, a list).
3. **One primary action per view.** Each window or pane has one obvious next step.
4. (inferred) **Nothing leaves the Mac.** Never trade privacy for a feature.
5. (inferred) **Plain words first, detail on request.**

## Accessibility & Inclusion

- Everything works with VoiceOver: every control named in plain words, icon-only buttons
  labelled, decorative icons hidden. `make test` and `make site-audit` check it (#346).
- Everything works from the keyboard.
- Contrast holds in light and dark, and with Increase Contrast.
- Colour is never the only signal: blocked and allowed also say so in words.
- (inferred) Respects Reduce Motion and Reduce Transparency.
