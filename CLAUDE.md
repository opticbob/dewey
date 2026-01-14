# Claude Code Configuration for Dewey

## Project Commands

### Development
- `bundle install` - Install Ruby dependencies
- `bundle exec ruby app.rb` - Start development server
- `bundle exec rerun ruby app.rb` - Start development server with auto-reload
- `bundle exec standard` - Run StandardRB linting
- `bundle exec standard --fix` - Auto-fix StandardRB issues

### Docker
- `docker build -t dewey .` - Build Docker image locally
- `docker-compose up` - Start application with Docker Compose
- `docker-compose up -d` - Start application in background
- `docker-compose down` - Stop and remove containers

### Testing
- `bundle exec ruby -Ilib -Itest test/test_*.rb` - Run tests (if implemented)

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