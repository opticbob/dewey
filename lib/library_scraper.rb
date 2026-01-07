require 'playwright'
require 'httparty'
require 'digest'
require 'uri'

class LibraryScraper
  def initialize(data_store, logger)
    @data_store = data_store
    @logger = logger
    @headless = ENV.fetch('PLAYWRIGHT_HEADLESS', 'true') == 'true'
  end

  def scrape_all_patrons
    patrons = get_patron_configs
    
    if patrons.empty?
      @logger.warn "No patron configurations found. Check environment variables."
      return
    end

    patrons.each do |patron|
      begin
        @logger.info "Starting scrape for patron: #{patron[:name]}"
        scrape_patron(patron)
      rescue => e
        @logger.error "Failed to scrape patron #{patron[:name]}: #{e.message}"
        @data_store.log_scrape_attempt(patron[:name], false, {}, e.message)
      end
    end
  end

  private

  def get_patron_configs
    patrons = []
    i = 1
    
    while ENV["PATRON_#{i}_NAME"]
      patrons << {
        name: ENV["PATRON_#{i}_NAME"],
        username: ENV["PATRON_#{i}_USER"],
        password: ENV["PATRON_#{i}_PASS"]
      }
      i += 1
    end
    
    patrons
  end

  def scrape_patron(patron)
    Playwright.create(playwright_cli_executable_path: './node_modules/.bin/playwright') do |playwright|
      browser = playwright.chromium.launch(headless: @headless)
      context = browser.new_context
      page = context.new_page

      begin
        login_to_library(page, patron)
        checkouts = scrape_checkouts(page, patron[:name])
        holds = scrape_holds(page, patron[:name])

        # Update data store
        all_checkouts = @data_store.get_checkouts
        all_holds = @data_store.get_holds

        # Remove old data for this patron and add new data
        all_checkouts.reject! { |item| item['patron_name'] == patron[:name] }
        all_holds.reject! { |item| item['patron_name'] == patron[:name] }
        
        all_checkouts.concat(checkouts)
        all_holds.concat(holds)

        @data_store.save_checkouts(all_checkouts)
        @data_store.save_holds(all_holds)

        @data_store.log_scrape_attempt(
          patron[:name],
          true,
          { checkouts: checkouts.length, holds: holds.length }
        )

        @logger.info "Successfully scraped patron #{patron[:name]}: #{checkouts.length} checkouts, #{holds.length} holds"

      ensure
        browser.close
      end
    end
  end

  def login_to_library(page, patron)
    library_url = ENV['LIBRARY_URL']
    raise "LIBRARY_URL environment variable not set" unless library_url

    @logger.debug "Navigating to library login page"
    page.goto(library_url)

    # ========================================
    # BIBLIOCOMMONS SELECTORS FOR LAWRENCE PUBLIC LIBRARY
    # ========================================
    # These selectors are configured for Bibliocommons library systems
    # If they stop working, inspect the login page and update as needed
    # ========================================

    # First click the "Sign In" button to open the login form
    SIGN_IN_BUTTON_SELECTOR = '.header-signin'
    
    # Bibliocommons login form selectors
    USERNAME_SELECTOR = '#name'
    PASSWORD_SELECTOR = '#user_pin'
    LOGIN_BUTTON_SELECTOR = 'input[type="submit"][name="commit"]'

    # Click the "Sign In" button first
    @logger.debug "Clicking sign in button"
    page.click(SIGN_IN_BUTTON_SELECTOR)
    
    # Wait for login form to appear
    page.wait_for_selector(USERNAME_SELECTOR, timeout: 5000)
    
    # Fill in credentials
    @logger.debug "Filling in login credentials"
    page.fill(USERNAME_SELECTOR, patron[:username])
    page.fill(PASSWORD_SELECTOR, patron[:password])
    
    # Submit login form
    @logger.debug "Submitting login form"
    page.click(LOGIN_BUTTON_SELECTOR)
    
    # Wait for login to complete - look for user menu or account elements
    LOGIN_SUCCESS_SELECTOR = '.dropdown-menu-user, .user-display-name, .header-user-menu'
    
    begin
      page.wait_for_selector(LOGIN_SUCCESS_SELECTOR, timeout: 10000)
      @logger.debug "Login successful"
    rescue Playwright::TimeoutError
      raise "Login failed or took too long. Check credentials and selectors."
    end
  end

  def scrape_checkouts(page, patron_name)
    @logger.debug "Scraping checkouts"
    
    # ========================================
    # BIBLIOCOMMONS CHECKOUTS SELECTORS
    # ========================================
    # Configured for Lawrence Public Library Bibliocommons system
    # ========================================

    # Navigate to checkouts page
    CHECKOUTS_PAGE_PATH = '/v2/checkedout'
    page.goto(ENV['LIBRARY_URL'] + CHECKOUTS_PAGE_PATH)

    # Wait for checkout items to load
    CHECKOUTS_CONTAINER_SELECTOR = '.cp-batch-actions-list, .checkedout-items-list'
    
    begin
      page.wait_for_selector(CHECKOUTS_CONTAINER_SELECTOR, timeout: 5000)
    rescue Playwright::TimeoutError
      @logger.warn "No checkouts container found, patron may have no items checked out"
      return []
    end

    # Bibliocommons checkout item selectors
    CHECKOUT_ITEM_SELECTOR = '.checkedout-item, .cp-batch-actions-item'
    TITLE_SELECTOR = '.title-content a, .cp-title a'
    AUTHOR_SELECTOR = '.cp-author-link, .author-link'
    DUE_DATE_SELECTOR = '.checkedout-item-due-date, .cp-due-date'
    TYPE_SELECTOR = '.cp-format-indicator, .format-indicator'
    THUMBNAIL_SELECTOR = '.cp-jacket-cover img, .jacket-cover img'
    RENEWABLE_SELECTOR = '.cp-batch-renew-checkbox, .renew-checkbox'

    checkout_items = page.locator(CHECKOUT_ITEM_SELECTOR).all

    checkouts = []
    
    checkout_items.each_with_index do |item, index|
      begin
        title = item.locator(TITLE_SELECTOR).text_content&.strip
        author = item.locator(AUTHOR_SELECTOR).text_content&.strip
        due_date = item.locator(DUE_DATE_SELECTOR).text_content&.strip
        item_type = item.locator(TYPE_SELECTOR).text_content&.strip || 'Book'
        
        # Check if item is renewable (this selector might not exist on all library systems)
        renewable = begin
          item.locator(RENEWABLE_SELECTOR).count > 0
        rescue
          false
        end

        # Get thumbnail URL if available
        thumbnail_url = begin
          img = item.locator(THUMBNAIL_SELECTOR).first
          img.get_attribute('src') if img
        rescue
          nil
        end

        # Generate a unique ID for this item (used for thumbnail storage)
        item_id = generate_item_id(title, author, patron_name)

        # Download and save thumbnail if we have a URL
        if thumbnail_url && !@data_store.thumbnail_exists?(item_id)
          download_thumbnail(thumbnail_url, item_id)
        end

        checkout = {
          'title' => title,
          'author' => author,
          'due_date' => parse_due_date(due_date),
          'type' => item_type,
          'renewable' => renewable,
          'patron_name' => patron_name,
          'thumbnail_url' => thumbnail_url ? "/thumbnails/#{item_id}.jpg" : '/placeholder.jpg',
          'item_id' => item_id
        }

        checkouts << checkout if title && !title.empty?

      rescue => e
        @logger.warn "Failed to parse checkout item #{index + 1}: #{e.message}"
      end
    end

    checkouts
  end

  def scrape_holds(page, patron_name)
    @logger.debug "Scraping holds"
    
    # ========================================
    # BIBLIOCOMMONS HOLDS SELECTORS
    # ========================================
    # Configured for Lawrence Public Library Bibliocommons system
    # Using the holds URL you provided: /v2/holds
    # ========================================

    # Navigate to holds page
    HOLDS_PAGE_PATH = '/v2/holds'
    page.goto(ENV['LIBRARY_URL'] + HOLDS_PAGE_PATH)

    # Wait for holds items to load
    HOLDS_CONTAINER_SELECTOR = '.cp-batch-actions-list, .holds-items-list'
    
    begin
      page.wait_for_selector(HOLDS_CONTAINER_SELECTOR, timeout: 5000)
    rescue Playwright::TimeoutError
      @logger.warn "No holds container found, patron may have no holds"
      return []
    end

    # Bibliocommons hold item selectors
    HOLD_ITEM_SELECTOR = '.holds-item, .cp-batch-actions-item'
    HOLD_TITLE_SELECTOR = '.title-content a, .cp-title a'
    HOLD_AUTHOR_SELECTOR = '.cp-author-link, .author-link'
    STATUS_SELECTOR = '.holds-item-status, .cp-holds-status'
    POSITION_SELECTOR = '.cp-queue-position, .queue-position'
    HOLD_THUMBNAIL_SELECTOR = '.cp-jacket-cover img, .jacket-cover img'

    hold_items = page.locator(HOLD_ITEM_SELECTOR).all

    holds = []
    
    hold_items.each_with_index do |item, index|
      begin
        title = item.locator(HOLD_TITLE_SELECTOR).text_content&.strip
        author = item.locator(HOLD_AUTHOR_SELECTOR).text_content&.strip
        status = item.locator(STATUS_SELECTOR).text_content&.strip
        
        # Get queue position if available (might not exist on all systems)
        position = begin
          pos_text = item.locator(POSITION_SELECTOR).text_content&.strip
          # Extract number from text like "Position 3 of 15" or "3"
          pos_text.match(/\d+/)&.to_s&.to_i if pos_text
        rescue
          nil
        end

        # Get thumbnail URL if available
        thumbnail_url = begin
          img = item.locator(HOLD_THUMBNAIL_SELECTOR).first
          img.get_attribute('src') if img
        rescue
          nil
        end

        # Generate a unique ID for this item
        item_id = generate_item_id(title, author, patron_name)

        # Download and save thumbnail if we have a URL
        if thumbnail_url && !@data_store.thumbnail_exists?(item_id)
          download_thumbnail(thumbnail_url, item_id)
        end

        hold = {
          'title' => title,
          'author' => author,
          'status' => status,
          'queue_position' => position,
          'patron_name' => patron_name,
          'thumbnail_url' => thumbnail_url ? "/thumbnails/#{item_id}.jpg" : '/placeholder.jpg',
          'item_id' => item_id
        }

        holds << hold if title && !title.empty?

      rescue => e
        @logger.warn "Failed to parse hold item #{index + 1}: #{e.message}"
      end
    end

    holds
  end

  def generate_item_id(title, author, patron_name)
    # Create a unique ID based on title, author, and patron
    text = "#{title}-#{author}-#{patron_name}".downcase
    Digest::MD5.hexdigest(text)[0..10]
  end

  def download_thumbnail(url, item_id)
    return unless url

    begin
      # Handle relative URLs
      url = URI.join(ENV['LIBRARY_URL'], url).to_s unless url.start_with?('http')
      
      @logger.debug "Downloading thumbnail: #{url}"
      response = HTTParty.get(url, timeout: 10)
      
      if response.success? && response.body.length > 0
        @data_store.save_thumbnail(item_id, response.body)
        @logger.debug "Saved thumbnail for item #{item_id}"
      end
    rescue => e
      @logger.warn "Failed to download thumbnail #{url}: #{e.message}"
    end
  end

  def parse_due_date(date_text)
    return nil unless date_text

    # ========================================
    # BIBLIOCOMMONS DATE PARSING
    # ========================================
    # Bibliocommons typically uses formats like:
    # - "Dec 15, 2024"
    # - "December 15, 2024"  
    # - "12/15/2024"
    # ========================================

    # Remove common prefixes and extra text
    cleaned_date = date_text.gsub(/^(due|expires?|return by)\s*/i, '').strip
    cleaned_date = cleaned_date.gsub(/\s*(renewal|overdue).*/i, '').strip

    # Bibliocommons date formats (most common first)
    date_formats = [
      '%b %d, %Y',     # Dec 15, 2024
      '%B %d, %Y',     # December 15, 2024
      '%m/%d/%Y',      # 12/15/2024
      '%m-%d-%Y',      # 12-15-2024
      '%Y-%m-%d',      # 2024-12-15
      '%d-%b-%y',      # 15-Dec-24
    ]

    date_formats.each do |format|
      begin
        parsed_date = Date.strptime(cleaned_date, format)
        return parsed_date.iso8601
      rescue Date::Error
        next
      end
    end

    # If no format worked, try natural language parsing
    begin
      require 'date'
      parsed_date = Date.parse(cleaned_date)
      return parsed_date.iso8601
    rescue Date::Error
      @logger.warn "Could not parse date: #{date_text} (cleaned: #{cleaned_date})"
      return cleaned_date # Return original if parsing fails
    end
  end
end