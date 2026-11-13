# The plan

NetworkMonitor shows the Mac's live network speed in the menu bar, which apps used the data,
which companies and countries they talk to, and blocks ads, trackers and anything you choose.
This plan is what comes next, in order: make what's there smooth and dependable, make ad
blocking the best a Mac app can do, then give the app a name people remember and launch it.

This file is the map. Each phase has its own page in [`phases/`](phases/), and on GitHub each
phase is a milestone and each piece of work an issue. [`phases/README.md`](phases/README.md)
lists everything open in order; it's written from GitHub, never by hand.

## Where we are

Shipped, as of 1.30.2 (11 Nov 2026):

- the menu bar readout (or a Dock icon instead) and its popover;
- which apps used the data, on which networks, by day, week, month or year;
- Connections: the companies, countries and servers each app talks to, on a list and a map,
  with a firewall to block any of them;
- ad, tracker and malware blocking in every app, from lists people know;
- Hotspot mode, the speed test, Settings, the redesign of 1.28, English and Chinese;
- signed with a Developer ID, notarized, and updating itself; a Homebrew tap; the website, with
  its docs pages and pictures kept current by tools.

**Releases are on hold** since 11 Nov 2026 (#559): what's merged waits on `main` until Kevin
says to release. The launch needs a fresh release, so the hold lifts before phase 7.

## Phases

Each phase ends with something people use. Phase numbers are names; the order is
[the roadmap](#the-roadmap) below.

| Phase | What it brings | Page |
|---|---|---|
| **1. Everyday polish** | The popover and the main window behave the same everywhere, without jumps; VoiceOver and keyboard checks finished | [01-everyday-polish](phases/01-everyday-polish.md) |
| **2. Ad blocking that holds up** | Pause from the menu bar, your own rules easy to find, and Enhanced ad blocking for ads inside pages and videos | [02-ad-blocking](phases/02-ad-blocking.md) |
| **3. The Chrome extension** | NetworkMonitor's own extension: in-page ads, pop-ups and YouTube ads, with the app's rules | [03-chrome-extension](phases/03-chrome-extension.md) |
| **4. Pictures, videos and docs** | Every picture and video shows today's app; each ⓘ opens its docs page; short videos on the docs | [04-pictures-and-docs](phases/04-pictures-and-docs.md) |
| **5. Releases people check first** | A beta channel, so Kevin and beta users see a version before everyone; the tooling kept in order | [05-releases](phases/05-releases.md) |
| **6. First run, name and logo** | A first run that explains every permission; a distinctive name, a stronger logo and the app's own website address | [06-first-run-and-brand](phases/06-first-run-and-brand.md) |
| **7. The launch** | The app polished, a launch video, posts where Mac users look, and a small ads experiment | [07-launch](phases/07-launch.md) |
| **8. Your data outside the app** | Ideas to decide: widgets, a Terminal command, asking an AI about the network | [08-data-outside-the-app](phases/08-data-outside-the-app.md) |

## The roadmap

The live roadmap is the project board, https://github.com/users/kevinabouhanna/projects/4.
Its views:

- **Now · Next · Later**: a board with a column for each, the items in order in each column.
- **Roadmap**: a timeline of the phases and items.
- **In order**: every open item and step in one list, grouped Now, Next, Later.
- **Inbox**: what Kevin adds by hand between sessions (below).

Each issue has a **Level** (Plan, Phase, Item or Step, from the tree), an **Order** (its place
in the roadmap; a step has its item's), a **Horizon** (Now, Next or Later) and rough **Start
date** and **Target date** on each item. The dates are guesses to put the work in order, not
promises; keep them current when the plan changes.

Why this order (13 Nov 2026, #605):

1. **What's rough every day comes first**: the popover's jump (#599) and the three windows that
   expand and filter differently (#593), then pausing ad blocking from the menu bar (#600) and
   a user's own rules, which they couldn't find (#592).
2. **Then the features that make ad blocking good** (Enhanced ad blocking, #256; the Chrome
   extension, #257), because they're what a launch will be judged on.
3. **Then everything people see from outside**: the pictures, videos and docs (#499, #230,
   #539), and betas so Kevin checks a version before everyone gets it (#585).
4. **The first run after the features**, because each feature adds a permission and the first
   run would be built twice otherwise (#522).
5. **The name, logo and website before the launch**, so the launch posts use the name people
   will search for (#582, #577).
6. **Ideas last**: widgets, a Terminal command and an AI, each decided before anything is built.

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
