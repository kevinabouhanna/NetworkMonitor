# The plan

NetworkMonitor shows the Mac's live network speed in the menu bar, which apps used the data,
which companies and countries they talk to, and blocks ads, trackers and anything you choose.
This plan is what comes next, in order: make what's there smooth and dependable, make ad
blocking the best a Mac app can do, then give the app a name people remember and launch it.

This file is the map. Each phase has its own page in [`phases/`](phases/), and on GitHub each
phase is a milestone and each piece of work an issue. [`phases/README.md`](phases/README.md)
lists everything open in order; it's written from GitHub, never by hand.

## Where we are

Shipped, as of 1.31.0 (14 Nov 2026):

- the menu bar readout (or a Dock icon instead) and its popover;
- which apps used the data, on which networks, by day, week, month or year;
- Connections: the companies, countries and servers each app talks to, on a list and a map,
  with a firewall to block any of them;
- ad, tracker and malware blocking in every app, from lists people know;
- Hotspot mode, the speed test, Settings, the redesign of 1.28, English and Chinese;
- signed with a Developer ID, notarized, and updating itself; a Homebrew tap; the website, with
  its docs pages and pictures kept current by tools.

1.31.0 (#643) brought all of phase 1 (the popover's one height, the three lists that behave
alike, the VoiceOver and keyboard checks), **Pause** ad blocking from the menu bar, and your own
**Rules** beside Traffic and Blocked, with its notes in Chinese too in the update window (#640).
Releases were on hold from 11 to 14 Nov 2026 (#559); releasing is routine again.

## Phases

Each phase ends with something people use. Phase numbers are names; the order is
[the roadmap](#the-roadmap) below.

| Phase | What it brings | Page |
|---|---|---|
| **1. Everyday polish** | The popover and the main window behave the same everywhere, without jumps; VoiceOver and keyboard checks finished | [01-everyday-polish](phases/01-everyday-polish.md) |
| **2. Ad blocking that holds up** | Enhanced ad blocking for ads inside pages and videos (Pause from the menu bar and your own rules are done) | [02-ad-blocking](phases/02-ad-blocking.md) |
| **3. The Chrome extension** | NetworkMonitor's own extension: in-page ads, pop-ups and YouTube ads, with the app's rules | [03-chrome-extension](phases/03-chrome-extension.md) |
| **4. Pictures, videos and docs** | Each ⓘ opens its docs page; after the new name, short videos on the docs and the launch video remade | [04-pictures-and-docs](phases/04-pictures-and-docs.md) |
| **5. Releases people check first** | 1.31.0 out; a beta channel, so Kevin and beta users see a version before everyone; the tooling kept in order | [05-releases](phases/05-releases.md) |
| **6. First run, name and logo** | A first run that explains every permission; a distinctive name, a stronger logo and the app's own website address | [06-first-run-and-brand](phases/06-first-run-and-brand.md) |
| **7. The launch** | The app polished, a launch video, posts where Mac users look, and a small ads experiment | [07-launch](phases/07-launch.md) |
| **8. Your data outside the app** | Ideas to decide: widgets, a Terminal command, asking an AI about the network | [08-data-outside-the-app](phases/08-data-outside-the-app.md) |

## The roadmap

The live roadmap is the project board, https://github.com/users/kevinabouhanna/projects/4,
with the same tabs as home-control's (#644):

- **Now · Next · Later**: a board with a column for each, the items in order in each column.
- **Now**, **Next** and **Later**: one list each, items and their steps, in order.
- **Inbox**: what Kevin adds by hand between sessions (below).
- **Roadmap**: a timeline of the phases and items.
- **In order**: every open item and step in one list, grouped Now, Next, Later.

Each issue has a **Level** (Plan, Phase, Item or Step, from the tree), an **Order** (its place
in the roadmap; a step has its item's), a **Horizon** (Now, Next or Later) and rough **Start
date** and **Target date** on each item. The dates are guesses to put the work in order, not
promises; keep them current when the plan changes.

Why this order (13 Nov 2026, #605; reviewed the same day, #644):

1. **Finished work reaches people first**: 1.31.0 (#643) took all of phase 1, Pause (#600)
   and Rules (#592) out on 14 Nov, the day Kevin said release (#559). Done.
2. **Then the feature that makes ad blocking good**: Enhanced ad blocking (#256), because it's
   what a launch will be judged on. Alongside, in the tooling item (#606), the window tests that
   fail while the screen is locked (#626), which stop every push while Kevin is away.
3. **Betas before Enhanced ad blocking ships** (#585): it opens secure connections, so beta
   users and Kevin see it before everyone.
4. **Then the ⓘ links into the docs** (#230), small and independent, **and the Chrome
   extension** (#257), the second half of ad blocking.
5. **The first run after the features**, because each feature adds a permission and the first
   run would be built twice otherwise (#522).
6. **The name, logo and website before anything that shows them**: the short videos (#539),
   the remade launch video (#458) and the launch itself (#577), so nothing is made twice and
   the launch posts use the name people will search for (#582).
7. **Ideas last**: widgets, a Terminal command and an AI, each decided before anything is built.

**What makes a good item** (#644): something people get, or a release that's due, named for
what it brings. Now and Next say exactly what's being built: when an item is an umbrella with
one real piece left, that piece becomes the item and the umbrella closes, so the board never
shows a name that only repeats its phase. Later items can be broad, and are split as they move
up. Now always holds the work being done or waiting on Kevin, never only the tooling item.

## How the plan is kept

On GitHub the plan is one tree of issues: the pinned root issue, "The plan: NetworkMonitor"
(label `plan`), whose description lists every item in order; under it a **phase issue** per
phase (the milestone's title, label `phase`, closed when the phase is done); under each phase
issue its **items**; under each item its **steps**. Tooling chores are steps of the standing
item #606, so every open issue has a place.

`Scripts/docs-kit plan sync` makes GitHub follow the tree and writes the root issue,
`phases/README.md` and each page's Status line from GitHub; `Scripts/docs-kit plan check`
(`make plan-check`, in CI) fails when the pages, the issues, the milestones or the board
disagree. Every session that changes the plan (a new issue, a new order, a phase finished)
changes the page and GitHub together, runs `plan sync`, then `plan check`, and commits the
pages in its pull request. It's product-kit's docs-kit, stage 1 (`.product-kit.json`'s
`plan`).

**The Inbox:** whatever Kevin wants to add between sessions (a bug, a feature, an idea,
something to research) goes in the board's **Inbox** view as a draft, with an optional
**Kind**. It isn't in the plan yet; when he says "scan the inbox", a session turns each entry
into an issue by its kind and fits it into the plan in order (`Scripts/docs-kit plan inbox`).
