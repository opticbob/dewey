# Changelog

Notable changes to Dewey, newest first.

The project is not versioned or released, so entries are grouped by the date
the work landed on `main` rather than by version number. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely: each entry
says what changed from a user's point of view, not which files moved.

## 2026-08-16

### Added

- **Renewal count on checked-out items**, shown as "2 of 4". Items auto-renew
  on their due date until they reach the library's limit, so an item at 4 of 4
  will not renew again; those are highlighted. BiblioCommons omits the label
  until an item has renewed once, which reads as zero.
- **"N people waiting"** on checked-out items another patron has requested.
  Such an item will not auto-renew however many renewals it has left, so the
  count is highlighted alongside the renewals — an item can read 0 of 4 and
  still be genuinely due.

## 2026-08-13

### Fixed

- **Times displayed in UTC.** The container runs without a timezone set, so
  "Last updated" and scrape times read several hours off — 22:10 rather than
  5:10 PM. Times now render in US Central with the zone shown, and follow
  daylight saving. Set `DISPLAY_TIME_ZONE` (or `TZ`) to use a different zone.

### Changed

- The site title in the header links back to the dashboard from any page.

## 2026-08-12

### Added

- **Back-to-top button.** Appears once the page is scrolled a screenful down
  and returns to the top. Works without JavaScript.
- **"Ready for Pickup" stat card**, counting holds waiting to be collected.
  Cards are now ordered checkouts-then-holds, with each linking to the table
  it summarises.
- **Missing-item marking.** An item the latest scrape did not return stays on
  the page, tinted and badged with how many scrapes have missed it, and is
  only dropped after `MISSING_SCRAPES_BEFORE_REMOVAL` scrapes (default 3).
  BiblioCommons intermittently serves a short list whose own page totals agree
  with it, so a single absence is not evidence an item is gone.
- **Test suite**: 117 tests covering the tracker, the data store, the
  scraper's browser-free logic, item extraction against saved BiblioCommons
  markup, and the app's scrape guard. Previously there were none.
- **CI**: a Tests workflow running the suite and StandardRB on every push and
  pull request.
- Stat cards are clickable on patron pages, not just the dashboard.
- Patron pages show only that patron's scrape failures.
- `/health` reports whether a scrape is currently running.

### Fixed

- **Truncated scrapes no longer wipe out data.** A timeout on a later page
  raised nothing, so the partial list was saved as if complete and every
  missing item was recorded as an unexpected disappearance. Roughly 22% of one
  patron's scrapes were corrupting their data this way. Such a scrape is now
  rejected and logged as a failure.
- **Holds pagination.** A patron whose holds exactly filled one page looked
  like they had a second page, because the "next page" check matched the
  "Select next month" buttons in every hold's date-picker calendar. The scrape
  then ran into an empty page and failed on nearly every run.
- **Duplicate disappearance reports.** An item missing for N scrapes recorded
  N identical disappearances, and its return was not recorded at all. Now
  reported once, with a matching event when it comes back.
- **Manual refresh could collide with a scheduled scrape**, starting a second
  concurrent login and ending the first session mid-run. `/refresh` now goes
  through the same guard as the scheduled runs.
- **Overdue items were also counted as due soon.** The two counts are now
  mutually exclusive, matching how individual rows were already coloured.
- **Mobile layout.** Tables ran off the side of the screen with no way to
  scroll to the cut-off columns. Rows now reflow into stacked cards on phones,
  and stat cards fit two across.
- Long scraper errors in the alert banner no longer push the page sideways.
- Container image attestation, which had been failing on every push to `main`
  because the job did not grant the OIDC permissions it needed.

### Changed

- **Upgraded to Ruby 4.0.6**, Node 24.19.0, Puma 8 and current gems.
  `playwright-ruby-client` is deliberately held at `~> 1.60.0`; 1.62.0 fails
  on browser launch even with its matching driver.
- GitHub Actions updated to versions that run on Node 24.
- Scrape failures are collapsed behind a count and expand on click, rather
  than filling the top of the page.

## 2026-08-11

### Fixed

- Transitions compared each scrape against the previous one rather than two
  scrapes back, which had reported items as disappeared while they were still
  present.
- Overlapping concurrent scrapes: Puma ran two workers, each with its own
  scheduler, so every scheduled scrape ran twice at once.
- Runaway pagination. BiblioCommons serves page 1 for out-of-range page
  numbers instead of a 404, so the scraper could page forever.
- Linux/Debian 13 deployment.

## 2026-08-05

### Added

- Physical vs digital breakdown on the checkout and hold stat cards.

## 2026-01-14

### Added

- Automatic thumbnail cleanup with configurable retention
  (`THUMBNAIL_RETENTION_DAYS`, default 90).

## 2026-01-13

### Added

- **SQLite item lifecycle tracking**, replacing the JSON-based missing-item
  log: snapshots of every scrape plus recorded state transitions, so
  unexpected disappearances can be told apart from normal returns.
- Alert banner surfacing recent scrape failures and their errors.
- Separate "Overdue" stat card.
- Configurable due-soon threshold (`DUE_SOON_DAYS`, default 5), and patron
  navigation is alphabetised.

## 2026-01-11

### Added

- Holds table with format, checkout-by dates and status-aware sorting: ready
  holds first by pickup deadline, then queued, then paused.
- Subtitles on scraped items, and clickable stat cards on the dashboard.

### Fixed

- Due-date comparisons use calendar days rather than 24-hour periods, so "due
  tomorrow" means tomorrow's date.

## 2026-01-09

### Changed

- Dashboard converted from a card grid to a compact table layout.
- Scraper performance and reliability work, including faster thumbnail
  extraction that no longer times out on large lists.

## 2026-01-06

### Added

- Initial release: BiblioCommons scraping for multiple patrons, a family
  dashboard and per-patron pages, a JSON API for Home Assistant, thumbnail
  caching, and scheduled scraping in Docker.
