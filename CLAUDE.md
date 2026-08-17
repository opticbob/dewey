# Claude Code Configuration for Dewey

## Project Commands

### Development
- `bundle install` - Install Ruby dependencies
- `bundle exec ruby app.rb` - Start development server
- `bundle exec rerun ruby app.rb` - Start development server with auto-reload
- `bundle exec standardrb` - Run StandardRB linting
- `bundle exec standardrb --fix` - Auto-fix StandardRB issues

### Docker
- `docker build -t dewey .` - Build Docker image locally
- `docker-compose up` - Start application with Docker Compose
- `docker-compose up -d` - Start application in background
- `docker-compose down` - Stop and remove containers

### Testing
- `bundle exec rake test` - Run the full suite
- `bundle exec ruby -Ilib -Itest test/test_item_tracker.rb` - Run one file

The extraction tests drive a real browser over saved fixtures; they skip if
no Playwright browser is installed, so check for skips before trusting a
green run.

## Changelog

Every commit that changes behaviour must add an entry to `CHANGELOG.md` in
the same commit, so the file never has to be reconstructed from `git log`.

- Entries are grouped by the date the work lands, newest first, under
  **Added**, **Fixed** or **Changed**. The project is not versioned, so there
  are no release headings.
- Write what changed for someone using Dewey, not which files moved. "Holds
  pagination no longer fails for a patron whose holds exactly fill a page"
  beats "update NEXT_BUTTON_SELECTOR".
- For a fix, say what was going wrong. The symptom is the useful part.
- Skip entries for changes with no observable effect: refactors, comment
  edits, test-only changes, formatting.
- Add to the existing dated section if one is already open for today.

### Playwright Setup (local development)

The scraper drives a real browser via `npx playwright`, so the Playwright **npm
package** must be installed separately from the gem — `bundle install` alone is
not enough.

```bash
npm install -g playwright@1.60.0   # must match the gem's COMPATIBLE_PLAYWRIGHT_VERSION
playwright install chromium        # downloads the browser binary
```

**Version pairing matters.** The `playwright-ruby-client` gem talks to the npm
driver over a private protocol and declares the exact version it expects in
`Playwright::COMPATIBLE_PLAYWRIGHT_VERSION`. To find the required npm version:

```bash
bundle exec ruby -e 'require "playwright"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION'
```

The gem and npm versions are *not* always identical — gem 1.57.1, for example,
was a gem-only patch that paired with npm 1.57.0. Always use the constant above
rather than assuming they match. A mismatch is not caught with a friendly error;
it surfaces as an obscure protocol failure or a hang at scrape time. When bumping
the gem, update the pinned npm version in `Dockerfile` and `Dockerfile.dev` too.

**`playwright-ruby-client` is held at `~> 1.60.0`.** Version 1.62.0 fails on
launch with `timeout: expected float, got undefined`, even with its matching
driver (npm 1.62.1) and on both Ruby 3.4 and 4.0. Re-test before relaxing that
pin; `bundle exec rake test` covers it, since the extraction tests launch a real
browser.

## Environment Variables

Configure by copying `.env.example` to `.env` and editing with your values:

```bash
cp .env.example .env
```

Required for library scraping:
- `LIBRARY_URL=https://lawrence.bibliocommons.com` - Your library URL
- `PATRON_1_NAME` - Display name for first family member
- `PATRON_1_USER` - Login username for first patron
- `PATRON_1_PASS` - Login password for first patron
- `PATRON_2_NAME` - Display name for second family member (optional)
- `PATRON_2_USER` - Login username for second patron (optional)  
- `PATRON_2_PASS` - Login password for second patron (optional)

Optional configuration:
- `PLAYWRIGHT_HEADLESS=true` - Set to 'false' for debugging
- `SCRAPE_INTERVAL=1` - Hours between scrapes
- `DUE_SOON_DAYS=5` - Number of days to consider items "due soon"
- `THUMBNAIL_RETENTION_DAYS=90` - Delete thumbnails not seen in X days
- `LOG_LEVEL=INFO` - Logging level: DEBUG, INFO, WARN, ERROR
- `DISPLAY_TIME_ZONE=America/Chicago` - Zone for displayed times. The
  container has no timezone set and would otherwise show UTC. An explicit
  `TZ` takes precedence.
- `MISSING_SCRAPES_BEFORE_REMOVAL=3` - Consecutive scrapes that may miss an
  item before it is dropped from the interface
- `PAGE_SETTLE_SECONDS=0.5` - Courtesy pause between page requests. Not a
  wait for content: navigations wait on the item list itself. Raise it to be
  gentler on the library's servers.

## API Endpoints

- `GET /api/status` - All library data (checkouts, holds, stats)
- `GET /api/patron/:name` - Data for specific patron
- `GET /api/missing-items` - Unexpected item disappearances (last 30 days)
- `GET /api/transitions?days=7&unexpected=true` - Item state transitions
- `GET /health` - Health check with last scrape time
- `POST /refresh` - Manual scrape trigger
- `POST /cleanup-thumbnails` - Manual thumbnail cleanup

## Project Structure
- `app.rb` - Main Sinatra application
- `lib/` - Ruby classes and modules
  - `data_store.rb` - JSON data storage for current state
  - `library_scraper.rb` - BiblioCommons web scraper
  - `item_tracker.rb` - SQLite-based item lifecycle tracking
- `views/` - ERB templates
- `data/` - Data storage directory
  - `checkouts.json`, `holds.json` - Current library items
  - `item_tracking.db` - SQLite database for historical tracking
  - `thumbnails/` - Cached item cover images
  - `scrape_log.json` - Scraping attempt history
- `config/` - Configuration files
- `.github/workflows/` - GitHub Actions for CI/CD

## Item Tracking with SQLite

Dewey uses SQLite to track item lifecycle and detect unexpected disappearances:

- **Snapshots**: Every scrape records a snapshot of all items
- **Transitions**: Tracks state changes (e.g., hold_waiting → hold_ready → checked_out)
- **Smart Detection**: Distinguishes expected transitions (returned near due date) from unexpected ones (digital hold vanishes)
- **Expected transitions**: hold progressing to ready, checkout returned near due date
- **Unexpected transitions**: items disappearing while waiting, ready holds vanishing

The database stores rich historical data for analytics and troubleshooting.

## Thumbnail Cleanup

Dewey automatically cleans up stale thumbnails:

- **Automatic**: Runs weekly on Sundays at 3 AM
- **Retention**: Keeps thumbnails for items seen in the last 90 days (configurable via `THUMBNAIL_RETENTION_DAYS`)
- **Manual**: Can be triggered via `POST /cleanup-thumbnails` endpoint
- **Scope**: Removes thumbnails for all items not seen recently, including missing/returned items

## Debugging with Playwright MCP

To customize the scraper for your library system:

1. Install Playwright MCP tool in Claude Code
2. Use it to navigate to your library website
3. Inspect the login form elements
4. Find CSS selectors for checkout and holds data
5. Update the selectors in `lib/library_scraper.rb`

## GitHub Container Registry Setup

1. Create GitHub Personal Access Token with `packages:write` permission
2. Add `GHCR_TOKEN` secret to GitHub repository
3. Workflow will build and push to `ghcr.io/USERNAME/dewey`