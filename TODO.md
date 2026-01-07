# Dewey Library Tracker - TODO

## Implementation Progress

### ✅ Completed
- [x] Project directory structure
- [x] Gemfile with Ruby 3.4.8 and dependencies (StandardRB)
- [x] Basic project files (config.ru, .gitignore)
- [x] CLAUDE.md configuration file

### 🚧 In Progress
- [ ] Create TODO.md file (this file)

### 📋 Pending

#### Core Application
- [ ] Set up Puma configuration
- [ ] Create main Sinatra app.rb with routing structure
- [ ] Implement JSON data storage handlers
- [ ] Build Playwright web scraper with browser automation
- [ ] Create ERB views for web dashboard
- [ ] Implement REST API endpoints
- [ ] Set up rufus-scheduler for automated scraping

#### Deployment & CI/CD
- [ ] Create Dockerfile with Ruby 3.4.8 and Playwright
- [ ] Build docker-compose.yml for deployment
- [ ] Create GitHub Actions workflow for GHCR
- [ ] Write comprehensive README.md

## Customization Notes

### Library Website Integration
The scraper will need customization for specific library systems. Key areas:
- Login form selectors
- Checkout table/list structure
- Holds queue structure
- Book thumbnail sources
- Due date formats

### Environment Variables Required
```env
LIBRARY_URL=https://your-library.org
PATRON_1_NAME=John
PATRON_1_USER=john.doe
PATRON_1_PASS=password123
PATRON_2_NAME=Jane
PATRON_2_USER=jane.doe
PATRON_2_PASS=password456
```

### GitHub Container Registry Setup
1. Create PAT with packages:write permission
2. Add GHCR_TOKEN to repository secrets
3. Configure workflow for automated builds
4. Deploy via docker-compose with ghcr.io image

## Development Workflow
1. Use Playwright MCP to inspect library website
2. Update CSS selectors in scraper
3. Test locally with `bundle exec rerun ruby app.rb`
4. Run StandardRB: `bundle exec standard`
5. Build Docker image and test
6. Push to main branch for automated GHCR build