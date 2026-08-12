# 📚 Dewey Library Tracker

A Ruby-based application that automatically scrapes your public library website to monitor your family's borrowing activity. Features a beautiful web dashboard and REST API for integration with Home Assistant or other home automation systems.

**Designed for BiblioCommons library systems** - Works with libraries using the BiblioCommons platform (e.g., lawrence.bibliocommons.com, catalog.yourlib.bibliocommons.com). The scraper can be adapted for other library systems by updating CSS selectors.

## ✨ Features

- **Automated Library Scraping**: Uses Playwright to log in and scrape checkout and hold data
- **Family-Wide Tracking**: Support for multiple library card holders
- **Web Dashboard**: Beautiful, responsive interface showing all library activity
- **REST API**: JSON endpoints for Home Assistant integration
- **Due Date Alerts**: Visual indicators for items due soon or overdue  
- **Book Thumbnails**: Automatically downloads and displays cover images
- **Docker Ready**: Containerized for easy deployment on home servers
- **GitHub Container Registry**: Automated builds and publishing

## 🏠 Home Lab Deployment

This application is designed to run in a Docker container on your home lab (Proxmox, Unraid, etc.) and pulls pre-built images from GitHub Container Registry.

## 🚀 Quick Start

### 1. Pull and Run with Docker Compose

1. **Create environment file from template:**
   ```bash
   cp .env.example .env
   ```

2. **Edit `.env` with your library credentials:**
   ```env
   LIBRARY_URL=https://lawrence.bibliocommons.com
   
   PATRON_1_NAME=John Doe
   PATRON_1_USER=john.library.username
   PATRON_1_PASS=john_library_password
   
   PATRON_2_NAME=Jane Doe
   PATRON_2_USER=jane.library.username
   PATRON_2_PASS=jane_library_password
   
   SCRAPE_INTERVAL=1
   LOG_LEVEL=INFO
   ```

3. **Create `docker-compose.yml` file:**
   ```yaml
   version: '3.8'
   
   services:
     dewey:
       image: ghcr.io/opticbob/dewey:latest
       container_name: dewey-library-tracker
       restart: unless-stopped
       ports:
         - "4567:4567"
       volumes:
         - ./data:/app/data
       env_file:
         - .env
   ```

Then run:

```bash
docker-compose up -d
```

### 2. Access the Dashboard

- **Web Interface**: http://your-server:4567
- **API Endpoint**: http://your-server:4567/api/status
- **Health Check**: http://your-server:4567/health

## ⚙️ Configuration

### Required Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `LIBRARY_URL` | Your library's website URL | `https://catalog.library.org` |
| `PATRON_1_NAME` | Display name for first family member | `John Doe` |
| `PATRON_1_USER` | Library username for first patron | `john.doe` |
| `PATRON_1_PASS` | Library password for first patron | `password123` |

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SCRAPE_INTERVAL` | `1` | Hours between automatic scrapes |
| `LOG_LEVEL` | `INFO` | Logging level (DEBUG, INFO, WARN, ERROR) |
| `PLAYWRIGHT_HEADLESS` | `true` | Set to `false` for debugging |

### Adding More Family Members

Simply add additional patron environment variables to your `.env` file:

```env
PATRON_3_NAME=Kid Doe
PATRON_3_USER=kid.library.username
PATRON_3_PASS=kid_library_password
```

## 🔧 Customizing for Your Library

The scraper needs to be customized for your specific library system. The code includes detailed placeholders showing exactly what needs to be changed.

### Using Playwright MCP Tool for Customization

1. **Install the Playwright MCP tool** in Claude Code
2. **Navigate to your library website** using the tool
3. **Inspect the login form** elements to find CSS selectors
4. **Examine checkout and holds pages** to identify data structure
5. **Update the selectors** in `lib/library_scraper.rb`

### Key Areas to Customize

**Login Selectors** (`lib/library_scraper.rb` lines 60-70):
```ruby
USERNAME_SELECTOR = '#username'          # Update this
PASSWORD_SELECTOR = '#password'          # Update this
LOGIN_BUTTON_SELECTOR = '#login-btn'     # Update this
```

**Checkout Page Selectors** (lines 90-110):
```ruby
CHECKOUTS_CONTAINER_SELECTOR = '.checkout-items'  # Update this
CHECKOUT_ITEM_SELECTOR = '.checkout-item'         # Update this
TITLE_SELECTOR = '.title'                         # Update this
# ... and more
```

**Holds Page Selectors** (lines 140-160):
```ruby
HOLDS_CONTAINER_SELECTOR = '.holds-items'  # Update this
HOLD_ITEM_SELECTOR = '.hold-item'          # Update this
# ... and more
```

### Step-by-Step Customization Guide

1. **Use Playwright MCP to inspect your library**:
   ```
   Navigate to: https://your-library.org
   ```

2. **Find the login form**:
   - Right-click username field → Inspect → Copy CSS selector
   - Right-click password field → Inspect → Copy CSS selector  
   - Right-click login button → Inspect → Copy CSS selector

3. **Navigate to account/checkouts page**:
   - Look for the container holding all checkout items
   - Find the pattern for individual items
   - Identify selectors for title, author, due date, etc.

4. **Navigate to holds/reservations page**:
   - Similar process for holds data

5. **Update the selectors in the code**:
   - Edit `lib/library_scraper.rb`
   - Replace placeholder selectors with your library's actual selectors
   - Test with `PLAYWRIGHT_HEADLESS=false` to debug

## 🏗️ Development Setup

### Local Development

```bash
git clone https://github.com/YOUR_USERNAME/dewey.git
cd dewey

# Copy environment template and fill in your details
cp .env.example .env

# Install dependencies
bundle install

# Install the Playwright browser driver (see note below)
npm install -g playwright@1.60.0
playwright install chromium

# Start development server with auto-reload
bundle exec rerun ruby app.rb
```

### Playwright Versions

The scraper launches a browser through `npx playwright`, so the Playwright npm
package is required in addition to the gem. The `playwright-ruby-client` gem
speaks a private protocol to that driver and pins the version it supports:

```bash
# Prints the npm version the installed gem requires
bundle exec ruby -e 'require "playwright"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION'
```

The gem and npm version numbers do not always line up — gem `1.57.1`, for
instance, paired with npm `1.57.0` because it was a gem-only release. Install
whatever the command above reports. A mismatched driver fails with a confusing
protocol error or a hang rather than a clear version warning, so it is worth
getting right up front. The same version is pinned in `Dockerfile` and
`Dockerfile.dev`; keep all three in sync when upgrading.

The gem is held at `~> 1.60.0`: version 1.62.0 fails on launch with
`timeout: expected float, got undefined` even when paired with its own driver.
`bundle exec rake test` will catch this if you try to move the pin.

### Running StandardRB

```bash
# Check code style
bundle exec standardrb

# Auto-fix style issues
bundle exec standardrb --fix
```

### Building Docker Image Locally

```bash
# Build image
docker build -t dewey .

# Run locally built image
docker run -p 4567:4567 --env-file .env dewey
```

## 📡 GitHub Container Registry Setup

### 1. Create GitHub Personal Access Token

1. Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Click "Generate new token (classic)"
3. Select scopes:
   - `read:packages`
   - `write:packages`
   - `delete:packages` (optional)
4. Copy the token (you'll need it for deployment)

### 2. Configure GitHub Secrets (for development)

If you're contributing to the project:

1. Go to your repository → Settings → Secrets and variables → Actions
2. Add repository secret:
   - Name: `GHCR_TOKEN`
   - Value: Your personal access token

### 3. Automated Builds

The GitHub Actions workflow automatically:
- Builds Docker images on push to `main` branch
- Pushes to `ghcr.io/YOUR_USERNAME/dewey:latest`
- Creates tagged releases for version tags
- Supports multi-architecture builds

## 🔌 Home Assistant Integration

### REST Sensor Configuration

Add this to your Home Assistant `configuration.yaml`:

```yaml
rest:
  - resource: "http://your-server:4567/api/status"  # Replace with your Dewey server IP/hostname
    scan_interval: 300
    sensor:
      - name: "Library Checkouts"
        value_template: "{{ value_json.stats.total_checkouts }}"
        unit_of_measurement: "books"
        
      - name: "Library Holds" 
        value_template: "{{ value_json.stats.total_holds }}"
        unit_of_measurement: "books"
        
      - name: "Books Due Soon"
        value_template: "{{ value_json.stats.items_due_soon }}"
        unit_of_measurement: "books"
```

### Template Sensors

```yaml
template:
  - sensor:
      - name: "Library Status"
        state: >
          {% if states('sensor.books_due_soon')|int > 0 %}
            Due Soon
          {% elif states('sensor.library_checkouts')|int > 0 %}
            Active
          {% else %}
            No Activity
          {% endif %}
```

## 🛠️ API Endpoints

| Endpoint | Description | Example Response |
|----------|-------------|------------------|
| `GET /` | Web dashboard | HTML interface |
| `GET /patron/:name` | Individual patron view | HTML interface |
| `GET /api/status` | Full family status | JSON with all data |
| `GET /api/patron/:name` | Individual patron API | JSON for specific patron |
| `GET /health` | Health check | `{"status": "ok"}` |
| `POST /refresh` | Manual refresh trigger | Redirects to dashboard |

### Example API Response

```json
{
  "checkouts": [
    {
      "title": "The Great Gatsby",
      "author": "F. Scott Fitzgerald",
      "due_date": "2024-12-15",
      "type": "Book",
      "renewable": true,
      "patron_name": "John Doe",
      "thumbnail_url": "/thumbnails/abc123.jpg"
    }
  ],
  "holds": [
    {
      "title": "Dune",
      "author": "Frank Herbert", 
      "status": "Ready for pickup",
      "queue_position": null,
      "patron_name": "Jane Doe",
      "thumbnail_url": "/thumbnails/def456.jpg"
    }
  ],
  "stats": {
    "total_checkouts": 1,
    "total_holds": 1, 
    "items_due_soon": 0,
    "patrons": ["John Doe", "Jane Doe"]
  },
  "last_updated": "2024-12-01T10:30:00Z"
}
```

## 🐛 Troubleshooting

### Scraping Issues

1. **Login failures**: 
   - Verify library URL and credentials
   - Check if library website structure changed
   - Set `PLAYWRIGHT_HEADLESS=false` to watch browser automation

2. **No data appearing**:
   - Check application logs: `docker-compose logs dewey`
   - Verify CSS selectors are correct for your library
   - Test manual refresh from web interface

3. **Missing thumbnails**:
   - Check if library provides thumbnail images
   - Verify image URLs are accessible
   - Check data volume permissions

### Docker Issues

1. **Container won't start**:
   ```bash
   # Check logs
   docker-compose logs dewey
   
   # Verify environment variables
   docker-compose config
   ```

2. **Permission issues**:
   ```bash
   # Fix data directory permissions
   sudo chown -R 1000:1000 ./data
   ```

### Common Library Website Changes

- **Login form changes**: Update selectors in `login_to_library` method
- **Checkout page layout**: Update selectors in `scrape_checkouts` method  
- **Holds page layout**: Update selectors in `scrape_holds` method
- **Date format changes**: Update `parse_due_date` method

## 📁 Project Structure

```
dewey/
├── app.rb                    # Main Sinatra application
├── lib/
│   ├── data_store.rb        # JSON data storage handler
│   └── library_scraper.rb   # Playwright web scraper
├── views/
│   ├── layout.erb           # HTML layout template
│   ├── dashboard.erb        # Family dashboard view
│   └── patron.erb          # Individual patron view
├── config/
│   └── puma.rb             # Puma server configuration
├── data/                   # Persistent data (created at runtime)
│   ├── checkouts.json      # Current checkout data
│   ├── holds.json          # Current holds data
│   ├── scrape_log.json     # Scraping activity log
│   └── thumbnails/         # Downloaded book cover images
├── public/
│   └── placeholder.jpg     # Fallback image for missing thumbnails
├── .github/workflows/
│   └── docker-build.yml    # GitHub Actions CI/CD
├── Dockerfile              # Container build instructions
├── docker-compose.yml      # Local deployment configuration
├── Gemfile                 # Ruby dependencies
└── README.md              # This file
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes and test thoroughly
4. Run StandardRB: `bundle exec standardrb`
5. Commit your changes: `git commit -am 'Add new feature'`
6. Push to the branch: `git push origin feature-name`
7. Create a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⭐ Acknowledgments

- Built with [Sinatra](http://sinatrarb.com/) web framework
- Browser automation powered by [Playwright](https://playwright.dev/)
- Designed for home lab deployment on [Proxmox](https://www.proxmox.com/)
- Follows [StandardRB](https://github.com/testdouble/standard) code style
- **Vibe coded with [Claude](https://claude.ai/)** - Developed through pair programming with Claude AI, using conversational development and iterative refinement

---

**Happy reading! 📖** Use Dewey to stay on top of your family's library activity and never miss a due date again.