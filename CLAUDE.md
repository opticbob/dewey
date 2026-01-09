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
- `LOG_LEVEL=INFO` - Logging level: DEBUG, INFO, WARN, ERROR

## API Endpoints

- `GET /api/status` - All library data (checkouts, holds, stats)
- `GET /api/patron/:name` - Data for specific patron
- `GET /api/missing-items` - Missing digital items tracking report
- `GET /health` - Health check with last scrape time
- `POST /refresh` - Manual scrape trigger

## Project Structure
- `app.rb` - Main Sinatra application
- `lib/` - Ruby classes and modules
- `views/` - ERB templates
- `data/` - JSON data files, thumbnails, and tracking logs
- `config/` - Configuration files
- `.github/workflows/` - GitHub Actions for CI/CD

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