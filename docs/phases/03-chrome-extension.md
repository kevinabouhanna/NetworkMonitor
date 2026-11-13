# Phase 3: The Chrome extension

**Milestone:** Phase 3: The Chrome extension · **Status:** Next

**Goal:** in Chrome (and Edge, Brave, Arc, Vivaldi), NetworkMonitor's own extension removes
what no app can reach from outside the page: in-page ads, pop-ups, the empty boxes ads leave,
and YouTube's ads. Kevin wants this to be NetworkMonitor, not uBlock Origin (#257).

## The plan

**A NetworkMonitor extension for Chrome** (#257), in steps:

1. block ad requests and hide ads, from EasyList and EasyPrivacy (#295), first, since the
   others build on it;
2. Block Ad Manually: pick an ad on the page and hide it for good (#296);
3. YouTube's ads, with our own code (#297);
4. one set of rules with the app, so the Ads window shows both (#298);
5. published on the Chrome Web Store, with Kevin's developer account (#299).
