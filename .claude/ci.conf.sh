# NetworkMonitor's CI for `local-ci <pr>` (shared-mac plugin, claude-parallel-sessions#12, #490):
# the two jobs of .github/workflows/ci.yml, `build-and-test` and `universal`, recorded on the
# commit under those names, so the merge rule reads the same. Pull requests run on this Mac only;
# GitHub Actions is for releases (`gh-actions can-run` first; CLAUDE.md).

CI_REPO=kevinabouhanna/NetworkMonitor
CI_JOBS=(build-and-test universal)
# One kept worktree (~/Library/Caches/networkmonitor-dev/ci/src) whose .build stays, so SwiftPM
# builds incrementally (its .build holds absolute paths, so a fresh worktree builds from cold).
CI_WORKTREE=kept
CI_KEEP=(.build)
nm_site="$HOME/Library/Caches/networkmonitor-dev/ci/site"

# The website as ci.yml finds it: gh-pages, or the pull request's branch with -site (#426).
ci_prepare() {
  local site_ref=gh-pages
  if [[ -n "$CI_HEAD" ]] && git -C "$CI_ROOT" ls-remote --exit-code --heads origin "$CI_HEAD-site" >/dev/null; then
    site_ref="$CI_HEAD-site"
  fi
  git -C "$CI_ROOT" fetch -q origin main "$site_ref"
  if [[ -e "$nm_site/.git" ]]; then git -C "$nm_site" checkout -q --detach -f "origin/$site_ref"
  else git -C "$CI_ROOT" worktree add -q --detach "$nm_site" "origin/$site_ref"; fi
}

# The smoke test runs in a throwaway VM (mac-vm): it takes no Mac lane and quits nothing, so it
# doesn't wait on a review build or the installed app (#528).
nm_smoke() {
  ./Scripts/smoke-test.sh
}

ci_job_build_and_test() {
  # The pull request's description can say a change is English only (#434).
  # …and that it needs no docs (#334).
  if [[ -n "$CI_PR" ]]; then PR="$CI_PR" make translation-check docs-check BASE=origin/main
  else PR_BODY="" make translation-check docs-check BASE=origin/main; fi
  swift build
  CI=true make test # as on GitHub: skips the tests that need live traffic
  GITHUB_BASE_REF=main GITHUB_HEAD_REF="$CI_HEAD" make asset-check SITE="$nm_site"
  make app
  codesign --verify --verbose=1 build/NetworkMonitor.app
  for f in Info.plist Resources/AppIcon.icns Resources/Geo/countries.bin Resources/Geo/owners.bin \
    Resources/Geo/world.bin Resources/Geo/README.md; do test -f "build/NetworkMonitor.app/Contents/$f"; done
  test -x build/NetworkMonitor.app/Contents/MacOS/NetworkMonitor
  (nm_smoke)
}

ci_job_universal() {
  make universal
  local archs; archs="$(lipo -archs build/NetworkMonitor.app/Contents/MacOS/NetworkMonitor)"
  echo "built: $archs"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]
}
