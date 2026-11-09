# Design overhaul log

The design work around #436: Settings › Connections and Settings › Ads open on the
numbers, with their setup behind a gear. Tracked in #437. This file is the record: what
the app looked like, what was planned and done, where ideas came from, what was decided
and by whom, and what's left.

**Status (2026-11-09):** Phases 0 and 1 are done. **Waiting on Kevin's review of
[`PRODUCT.md`](../../PRODUCT.md) and [`DESIGN.md`](../../DESIGN.md)** before Phase 2.
Nothing merges or releases until Kevin has reviewed it: both pull requests are drafts.

Contents: [1. Before](#1-before) · [2. Plan](#2-plan) · [3. Inspiration](#3-inspiration) ·
[4. Decisions](#4-decisions) · [5. After](#5-after) · [6. Audit](#6-audit) ·
[7. My own touches](#7-my-own-touches) · [8. Open questions](#8-open-questions)

## 1. Before

`main` at 5c1bfb8 (1.26.7 and the language choice, #433), drawn by `make design-shots` from made-up data (see
[7](#7-my-own-touches)): none of Kevin's connections, sites or rules. Every picture is at
2x. Drawn at about 5 AM, so today's charts have five hours in them; the made-up day is
shifted so those hours are busy.

### How it's laid out

- **The popover** (from the menu bar) is the everyday surface; it opens the windows.
- **Settings** (⌘,) has seven panes behind a toolbar of labelled icons: General, Speed
  Test, History, Connections, Ads, Hotspot, About. One width (720 pt) for all.
  - **History** opens on the numbers: period, a chart, then apps, networks or sessions,
    with the history settings at the bottom.
  - **Connections** opens on a sentence and *Open Connections…*, then four sections of
    setup: the blocking mode and every rule, encrypted lookups, which layout the window
    opens with, and the countries data. 900 pt tall with three rules. No numbers.
  - **Ads** opens on a sentence and *Open Ads and Trackers…*, then the lists' switches,
    *Blocked today* (the one number, fourth row down), the weekly update, then more lists
    and your rules, each with a button into the Ads and Trackers window.
- **Connections** (⌘K): toolbar with list / both / map, the period, ‹ Today › and search;
  a scope row (Group by, Show, and All / Wi-Fi / Hotspot); "Today" with one line of
  totals; a timeline; then the list, and the map beside it or instead of it.
- **Ads and Trackers** (⌘B): the period and ‹ Today › in the toolbar (Overview only), the
  four tabs at the top of the content (#358). Overview leads with "459 blocked", the
  lists' counts, a chart, then Sites and Apps side by side. Log, Lists and Rules are
  where lists and rules are managed.

### How it flows

To see what was blocked today, someone in Settings › Ads reads past the switches to the
fourth row, or opens the window. To see who their Mac talked to, someone in Settings ›
Connections must open the window: the pane has no numbers at all (#189 took the Today
list out). History, the pane between them, opens on its numbers. So the three
data-shaped panes behave three different ways.

### Pain points

1. **Settings › Connections and › Ads are setup-first.** The thing most people come to
   see (what happened) isn't there or is buried; the setup most people never change is
   what they read first. This is #436.
2. **The same settings live in two places.** The lists' switches are in Settings › Ads
   and in Ads and Trackers › Lists; ad rules are counted in Settings and edited in the
   window; firewall rules are listed in Settings › Connections and made by right-clicking
   in the window. Two homes for one thing, and no rule for which is the real one.
3. **Settings › Connections is long and mixed.** Blocking, lookups, a layout preference
   and a data source sit in one scroll, with a footnote under each.
4. **Three charts, three styles.** Connections' timeline has no axis and square bars;
   History's has an axis, gridlines and rounded bars; Ads and Trackers' has dashed
   gridlines and red bars.
5. **Thirteen type sizes** between 8 and 32 pt, and eight corner radii. Tags are 8 pt.
6. **Empty states read oddly.** Connections with no data: "0 B to and from servers ·
   0 companies · 0 countries · 0 apps · 0 servers", an empty timeline, a blank map, and
   "No connections in this day. Connections are recorded from this version on", which
   speaks to someone updating, not someone new. Ads and Trackers' "Ad blocking is off ·
   Turn On" is the good pattern to follow.
7. **Companies named after a site** read as made-up words: "Theguardian",
   "Ycombinator", and "Me" for Apple's me.com. Out of scope here (naming, not layout);
   listed in [8](#8-open-questions).
8. **Settings holds data.** macOS's guidelines keep the Settings window for preferences;
   History already puts a data view there, and #436 would add two more. See
   [8](#8-open-questions): it shapes the options in Phase 3.

### Pictures

| State | Dark | Light |
|---|---|---|
| Settings › General | <img src="before/settings-general-dark.png" width="360" alt="Settings › General, dark"> | <img src="before/settings-general-light.png" width="360" alt="Settings › General, light"> |
| Settings › Connections | <img src="before/settings-connections-dark.png" width="360" alt="Settings › Connections, dark"> | <img src="before/settings-connections-light.png" width="360" alt="Settings › Connections, light"> |
| Settings › Ads | <img src="before/settings-ads-dark.png" width="360" alt="Settings › Ads, dark"> | <img src="before/settings-ads-light.png" width="360" alt="Settings › Ads, light"> |
| Settings › History | <img src="before/settings-history-dark.png" width="360" alt="Settings › History, dark"> | <img src="before/settings-history-light.png" width="360" alt="Settings › History, light"> |
| Connections, list | <img src="before/connections-list-dark.png" width="360" alt="Connections, list, dark"> | <img src="before/connections-list-light.png" width="360" alt="Connections, list, light"> |
| Connections, list and map | <img src="before/connections-both-dark.png" width="360" alt="Connections, list and map, dark"> | <img src="before/connections-both-light.png" width="360" alt="Connections, list and map, light"> |
| Connections, map | <img src="before/connections-map-dark.png" width="360" alt="Connections, map, dark"> | <img src="before/connections-map-light.png" width="360" alt="Connections, map, light"> |
| Ads and Trackers › Overview | <img src="before/ads-overview-dark.png" width="360" alt="Ads and Trackers › Overview, dark"> | <img src="before/ads-overview-light.png" width="360" alt="Ads and Trackers › Overview, light"> |
| Ads and Trackers › Log | <img src="before/ads-log-dark.png" width="360" alt="Ads and Trackers › Log, dark"> | <img src="before/ads-log-light.png" width="360" alt="Ads and Trackers › Log, light"> |
| Ads and Trackers › Lists | <img src="before/ads-lists-dark.png" width="360" alt="Ads and Trackers › Lists, dark"> | <img src="before/ads-lists-light.png" width="360" alt="Ads and Trackers › Lists, light"> |
| Ads and Trackers › Rules | <img src="before/ads-rules-dark.png" width="360" alt="Ads and Trackers › Rules, dark"> | <img src="before/ads-rules-light.png" width="360" alt="Ads and Trackers › Rules, light"> |

| State | No data, ad blocking off | First launch: no data, filter not set up |
|---|---|---|
| Settings › General | <img src="before/empty-settings-general-dark.png" width="360" alt="Settings › General with no data"> | <img src="before/first-settings-general-dark.png" width="360" alt="Settings › General on a first launch"> |
| Settings › Connections | <img src="before/empty-settings-connections-dark.png" width="360" alt="Settings › Connections with no data"> | <img src="before/first-settings-connections-dark.png" width="360" alt="Settings › Connections on a first launch"> |
| Settings › Ads | <img src="before/empty-settings-ads-dark.png" width="360" alt="Settings › Ads with no data"> | <img src="before/first-settings-ads-dark.png" width="360" alt="Settings › Ads on a first launch"> |
| Settings › History | <img src="before/empty-settings-history-dark.png" width="360" alt="Settings › History with no data"> | <img src="before/first-settings-history-dark.png" width="360" alt="Settings › History on a first launch"> |
| Connections, list | <img src="before/empty-connections-list-dark.png" width="360" alt="Connections, list with no data"> | <img src="before/first-connections-list-dark.png" width="360" alt="Connections, list on a first launch"> |
| Connections, list and map | <img src="before/empty-connections-both-dark.png" width="360" alt="Connections, list and map with no data"> | <img src="before/first-connections-both-dark.png" width="360" alt="Connections, list and map on a first launch"> |
| Connections, map | <img src="before/empty-connections-map-dark.png" width="360" alt="Connections, map with no data"> | <img src="before/first-connections-map-dark.png" width="360" alt="Connections, map on a first launch"> |
| Ads and Trackers › Overview | <img src="before/empty-ads-overview-dark.png" width="360" alt="Ads and Trackers › Overview with no data"> | <img src="before/first-ads-overview-dark.png" width="360" alt="Ads and Trackers › Overview on a first launch"> |
| Ads and Trackers › Log | <img src="before/empty-ads-log-dark.png" width="360" alt="Ads and Trackers › Log with no data"> | <img src="before/first-ads-log-dark.png" width="360" alt="Ads and Trackers › Log on a first launch"> |
| Ads and Trackers › Lists | <img src="before/empty-ads-lists-dark.png" width="360" alt="Ads and Trackers › Lists with no data"> | <img src="before/first-ads-lists-dark.png" width="360" alt="Ads and Trackers › Lists on a first launch"> |
| Ads and Trackers › Rules | <img src="before/empty-ads-rules-dark.png" width="360" alt="Ads and Trackers › Rules with no data"> | <img src="before/first-ads-rules-dark.png" width="360" alt="Ads and Trackers › Rules on a first launch"> |

## 2. Plan

Two draft pull requests, plus a page that shows the pictures side by side for Kevin.
Neither merges until Kevin has reviewed it.

| Phase | What | Status |
|---|---|---|
| 0. Baseline | Pictures of every state; structure and pain points; baseline audit | **Done** (2026-11-09) |
| 1. Context | `PRODUCT.md` and `DESIGN.md` | **Drafted; waiting on Kevin's review** |
| 2. Research | Inspo, 3–5 references, plus native Mac apps described in words | Not started: waits on Phase 1's review |
| 3. Define | 2–3 options for the stats view and for the settings entry; a recommendation | Not started; **waits on Kevin's approval of one option** |
| 4. Build | #436 in small commits, then Impeccable's layout, typeset, clarify, distill, and polish last | Pull request 2 |
| 5. Critique | Audit again against the baseline; contrast, keyboard, VoiceOver, minimum size, light and dark, long names, empty and first-launch states | Pull request 2 |

### What changed from the brief, and why

- **Pictures are drawn from made-up data**, not taken from the installed app (Kevin
  agreed, 2026-11-09). The installed app shows Kevin's real connections, blocked sites
  and rules, and this repository is public. `make design-shots` builds each window in its
  own process with a made-up history, its own settings and a content filter that says
  it's on, and captures it. The same states come out before and after, in light and
  dark, with no data and on a first launch.
- **The windows' buttons show as inactive (grey).** The windows are drawn out of sight so
  nothing steals the focus from Kevin's screen, and the window server draws an inactive
  window's buttons in grey. Before and after are drawn the same way.
- **No VoiceOver trees from the installed app** (`site-shots tree`) for the baseline: they
  would read Kevin's real rows. `make test` builds every window in every language and
  passed: 797 tests, every window naming everything VoiceOver reads.
- **Impeccable doesn't know macOS.** Its platforms are `web`, `ios`, `android` and
  `adaptive`; `PRODUCT.md` says `macos`, which Impeccable reads as `web` (it warns so).
  Its web guidance doesn't apply and isn't followed. Its native audit's five scores are
  used, with the macOS Human Interface Guidelines in place of its iOS reference (44 pt
  touch targets, tab bars, Dynamic Type, the Simulator), and are marked *adapted*.
- **Impeccable's detector hook isn't enabled:** it reads only web files (`.tsx`, `.css`,
  `.html` and the like), never `.swift`. Manual checks instead, in Phase 5.
- **`/impeccable init`'s interview** was answered by Kevin's brief and the repository;
  his review of `PRODUCT.md` stands in for it. Anything not from him is marked
  *(inferred)* there.
- **`/impeccable document`** wrote `DESIGN.md` with no colour, type, radius or spacing
  tokens: the app uses the system's semantic colours and text, which change with
  appearance and accessibility settings, so a hex or px value would be invented. It
  wrote no `.impeccable/design.json` either: that holds HTML/CSS for Impeccable's
  browser panel.

## 3. Inspiration

Phase 2, after Kevin's review of Phase 1. Each reference will be listed with its name,
link, what we took and what we rejected. Inspo's screens are other designers' work: they
are used for ideas only, and credited here.

## 4. Decisions

| # | Decision | Options | Status |
|---|---|---|---|
| D1 | Pictures from made-up data | Real data from the installed app; made-up data | **Approved by Kevin**, 2026-11-09 |
| D2 | Two draft pull requests and a comparison page | One pull request; two | **Approved by Kevin**, 2026-11-09 |
| D3 | How to use tools made for the web | Use them as they are; adapt them to the Mac (above) | Proposed 2026-11-09; Kevin didn't object |
| D4 | The stats-first layout | Phase 3 | Not yet |
| D5 | Where the settings go (gear, inspector, sheet) | Phase 3 | Not yet |

## 5. After

Phase 5: the same states as [Before](#1-before), side by side.

## 6. Audit

### Baseline: 15/20, Good (adapted)

Impeccable's native audit (`audit.native.md`), scored against the macOS Human Interface
Guidelines rather than its iOS reference. Read from the code and the pictures above.

| # | Dimension | Score | Key finding |
|---|---|---|---|
| 1 | Accessibility | 3 | Every control named in every window and language (`make test`). Tags at 8 pt; keyboard order, VoiceOver order and contrast not yet measured |
| 2 | Performance | 3 | Not measured here. Lazy lists, a throttled log, about 1% of one core (README) |
| 3 | Appearance & theming | 3 | Semantic colours, both appearances first-class; thirteen fixed type sizes and eight radii |
| 4 | Platform conformance | 3 | Native throughout. Data views in the Settings window, and the same settings in two places |
| 5 | Adaptivity | 3 | Minimum widths measured on the app; list and map fold to the list when narrow. Empty states uneven; Chinese not yet seen in these windows |
| **Total** | | **15/20** | **Good** |

**Platform conformance verdict:** passes. It reads as a Mac app: real toolbars, system
segmented controls, grouped Settings forms, SF Symbols, semantic colours. Nothing in it
looks ported from a website.

**Findings by severity**

- **[P1] Settings › Connections and › Ads lead with setup.** Settings › Connections has
  no numbers; Settings › Ads has one, fourth row down. Most visits are to see what
  happened (`PRODUCT.md`). This is #436. *Suggested: `/impeccable layout`, `distill`.*
- **[P1] The same settings in two places.** Lists, ad rules and firewall rules each live
  in Settings and in a window, with no rule for which is home. *`distill`.*
- **[P2] Data in the Settings window.** The guidelines keep Settings for preferences;
  History is already a data view there, and #436 would add two. See question 1 below.
  *`shape`.*
- **[P2] Three chart styles** for one kind of chart (Connections, History, Ads and
  Trackers). *`layout`.*
- **[P2] The type scale:** thirteen sizes from 8 to 32 pt; tags at 8–9 pt are below
  comfortable reading size. *`typeset`.*
- **[P2] Empty Connections reads as a row of zeros**, with a blank map and wording for
  someone updating. *`onboard`, `clarify`.*
- **[P3] Eight corner radii** (2–10 pt). *`polish`.*

**Not yet checked, for Phase 5 on before and after alike:** contrast measured from the
pictures, keyboard-only use, VoiceOver's reading order, Increase Contrast, Reduce
Transparency and Reduce Motion, and the windows in Chinese.

**What works:** the windows' one-column reading order (scope, period, totals, chart,
list); figures right-aligned in tabular digits; colours always named in words (BLOCKED,
ALWAYS ALLOWED); explanations behind an ⓘ; Ads and Trackers' empty state.

## 7. My own touches

Beyond what the tools suggested. **Review these separately.**

1. **`make design-shots`** (`Sources/DesignShots`, the `Makefile`): draws every window
   from made-up data, in light and dark, with no data and on a first launch, at 2x,
   without the installed app, the Mac lane or the focus. In English for the United
   States, so the pictures don't depend on who takes them (the map marks the Mac's
   region as home). It needed one addition to the app's code:
   `FilterController.showForPictures(_:)`, in debug builds only (the app is always
   built for release), so the windows can show the content filter as on.
2. **The asset check now reads every page under `docs/`, in folders too**, so this log's
   pictures are checked (part of #425). They're listed in
   `Resources/README/assets.json` as a dated record that shows no window to keep
   current.
3. **The made-up data:** seven apps (one with a long name, "Northwind Field Operations
   Companion"), twelve companies, two weeks of traffic on a home Wi-Fi and one afternoon
   a week on a phone's hotspot, three firewall rules, two ad rules, and eight kinds of
   blocked site. The day is shifted so whenever it's drawn, the hours so far look like a
   working day.
4. **A north star for `DESIGN.md`:** "The quiet instrument". Rename or drop it.
5. **Pain points 7 and 8** in [Before](#1-before) go beyond #436.
6. **The *(inferred)* lines in `PRODUCT.md`**: the metered-connection user, the
   positioning, how long a visit lasts, and principles 4 and 5.

## 8. Open questions

For Kevin, before Phase 2:

1. **Should the numbers live in Settings at all?** The Mac's guidelines keep the
   Settings window for preferences. #436 adds numbers to two Settings panes (History
   already has them). Phase 3 can offer both directions:
   - **A: as #436 says.** Settings › Connections and › Ads open on the numbers, with the
     setup behind a gear.
   - **B: the other way round.** Settings › Connections and › Ads stay setup, but
     shorter. The Connections and Ads and Trackers windows, which already open on the
     numbers, gain the gear for their own setup, so each setting has one home.

   Is B worth showing, or is A decided?
2. **`PRODUCT.md`:** are the *(inferred)* lines right? Anything missing about who uses it?
3. **`DESIGN.md`:** keep "The quiet instrument", or another name? Is anything in it not
   how you see the app?
4. **The pictures weigh 8.8 MB per set, about 18 MB with the after set.** Keep them in
   the repository, or only the dark ones?
5. **#402** (the ad blocking numbers disagree): fix it before #436 ships, since stats
   first puts those numbers forward?
6. **Companies named after a site** ("Theguardian", "Me" for me.com): a separate issue?
