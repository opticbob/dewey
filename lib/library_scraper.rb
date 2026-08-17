require "playwright"
require "httparty"
require "digest"
require "uri"
require "fileutils"
require_relative "item_tracker"

class LibraryScraper
  # Raised when a scrape cannot be completed in full. Partial results must not
  # be recorded: the tracker compares against the previous snapshot, so a
  # truncated list looks exactly like the missing items having disappeared.
  class IncompleteScrapeError < StandardError; end

  # Pause between page loads, to stay polite to the library's servers.
  #
  # This used to be 2s (3s after a navigation) and was the single largest cost
  # in a scrape, about 39% of the cycle. page.goto already blocks until the
  # page has loaded, and measuring against the live site showed the item
  # container present 0.02-0.04s later with the item count unchanged after a
  # further 2s -- so the wait was not buying settling time, it was idling.
  # Navigations now wait on the container instead, and this is only the
  # courtesy gap between requests.
  def self.page_settle_seconds
    Float(ENV.fetch("PAGE_SETTLE_SECONDS", "0.5"))
  end

  # How long to wait for a list container to appear after a navigation.
  # Generous: it is a ceiling, not a delay, and only reached when something
  # is actually wrong.
  CONTAINER_TIMEOUT_MS = 15_000

  # Items auto-renew on their due date until they hit the library's limit, so
  # an item at the maximum will not renew again. Used to flag those in the
  # interface rather than to cap anything during scraping.
  MAX_RENEWALS = 4

  # How many consecutive scrapes may miss an item before it is dropped from
  # the interface. BiblioCommons sometimes serves a short list that its own
  # page totals agree with, so a single absence is not evidence an item is
  # gone; it is usually back on the next scrape. Until this many scrapes have
  # missed it, the item stays on the page flagged as missing.
  def self.missing_scrapes_before_removal
    Integer(ENV.fetch("MISSING_SCRAPES_BEFORE_REMOVAL", "3"))
  end

  # Bibliocommons CSS selectors for Lawrence Public Library
  SIGN_IN_BUTTON_SELECTOR = 'a[href="/user/login"]'
  USERNAME_SELECTOR = 'input[name="name"]'
  PASSWORD_SELECTOR = 'input[name="user_pin"]'
  LOGIN_BUTTON_SELECTOR = 'input[type="submit"][name="commit"]'
  LOGIN_SUCCESS_SELECTOR = ".dropdown-menu-user, .user-display-name, .header-user-menu"

  CHECKOUTS_PAGE_PATH = "/v2/checkedout"
  CHECKOUTS_CONTAINER_SELECTOR = ".cp-batch-actions-list"
  CHECKOUT_ITEM_SELECTOR = ".batch-actions-list-item-details"
  TITLE_SELECTOR = ".cp-title .title-content"
  SUBTITLE_SELECTOR = ".cp-subtitle"
  AUTHOR_SELECTOR = ".cp-author-link a"
  DUE_DATE_SELECTOR = ".cp-short-formatted-date"
  TYPE_SELECTOR = ".display-info-primary"
  THUMBNAIL_SELECTOR = ".jacket-cover-container img"
  RENEWABLE_SELECTOR = ".cp-batch-renew-checkbox"
  RENEW_COUNT_SELECTOR = ".cp-renew-count"
  HELD_COPIES_SELECTOR = ".cp-held-copies-count"
  STATUS_SELECTOR = ".status-name"

  HOLDS_PAGE_PATH = "/v2/holds"
  HOLDS_CONTAINER_SELECTOR = ".cp-batch-actions-list"
  HOLD_ITEM_SELECTOR = ".batch-actions-list-item-details"
  # Note: Holds use the same title/author selectors as checkouts
  HOLD_TITLE_SELECTOR = ".title-content"
  HOLD_AUTHOR_SELECTOR = ".author-link"
  HOLD_STATUS_SELECTOR = ".status-name"
  POSITION_SELECTOR = ".cp-hold-position"
  HOLD_THUMBNAIL_SELECTOR = ".jacket-cover-container img"
  HOLD_TYPE_SELECTOR = ".display-info-primary"
  CHECKOUT_BY_DATE_SELECTOR = ".cp-pick-up-date .cp-short-formatted-date"
  HOLD_EXPIRY_DATE_SELECTOR = ".cp-hold-expiry-date .cp-short-formatted-date"

  # Pagination selectors for Bibliocommons.
  #
  # The "next" control must be scoped to the pagination nav. Unscoped, an
  # aria-label match also catches the "Select next month" buttons in the
  # date-picker calendars that every hold renders, so a patron whose holds
  # exactly fill a page looked like it had another page and the scrape ran on
  # into an empty one.
  PAGINATION_ITEM_SELECTOR = "a.pagination-item__link[data-page]"
  NEXT_BUTTON_SELECTOR = '.cp-pagination button[aria-label*="next" i]:not([disabled]), ' \
                         '.cp-pagination a[aria-label*="next" i]'
  PAGINATION_SELECTOR = ".cp-pagination-item"  # Legacy fallback

  # Hard safety cap on pagination. BiblioCommons serves page 1's content for
  # out-of-range ?page=N values rather than 404ing, so a "next" control that is
  # always present will otherwise walk forever. Real accounts never come close
  # to this many pages.
  MAX_PAGES = 25

  def initialize(data_store, logger)
    @data_store = data_store
    @logger = logger
    @headless = ENV.fetch("PLAYWRIGHT_HEADLESS", "true") == "true"
    @item_tracker = ItemTracker.new(@data_store.data_dir)
  end

  def scrape_all_patrons
    patrons = get_patron_configs

    if patrons.empty?
      @logger.warn "No patron configurations found. Check environment variables."
      return
    end

    # One driver and browser for the whole run. Each patron previously spawned
    # its own Playwright driver process and browser, which cost a few seconds
    # per cycle for no benefit -- the session isolation that matters comes
    # from a fresh context, which scrape_patron still creates per patron.
    Playwright.create(playwright_cli_executable_path: "npx playwright") do |playwright|
      browser = playwright.chromium.launch(headless: @headless)

      begin
        patrons.each do |patron|
          @logger.info "Starting scrape for patron: #{patron[:name]}"
          scrape_patron(patron, browser)
        rescue => e
          @logger.error "Failed to scrape patron #{patron[:name]}: #{e.message}"
          @data_store.log_scrape_attempt(patron[:name], false, {}, e.message)
        end
      ensure
        browser.close
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

  # Each patron gets a fresh browser context, so cookies and the logged-in
  # session do not leak from one library account to the next. The browser
  # itself is shared across patrons and closed by the caller.
  def scrape_patron(patron, browser)
    patron_start_time = Time.now
    @logger.info "\n" + "█" * 80
    @logger.info "█ STARTING FULL SCRAPE FOR PATRON: #{patron[:name]}"
    @logger.info "█" * 80

    context = browser.new_context
    page = context.new_page

    begin
      login_start = Time.now
      @logger.info "\nLogging in to library..."
      login_to_library(page, patron)
      login_elapsed = Time.now - login_start
      @logger.info "Login complete in #{format_duration(login_elapsed)}"

      checkouts = scrape_checkouts(page, patron[:name])
      holds = scrape_holds(page, patron[:name])

      # Update data store
      @logger.info "\nUpdating data store..."
      data_store_start = Time.now

      all_checkouts = @data_store.get_checkouts
      all_holds = @data_store.get_holds

      previous_checkouts = all_checkouts.select { |item| item["patron_name"] == patron[:name] }
      previous_holds = all_holds.select { |item| item["patron_name"] == patron[:name] }

      # Remove old data for this patron and add new data
      all_checkouts.reject! { |item| item["patron_name"] == patron[:name] }
      all_holds.reject! { |item| item["patron_name"] == patron[:name] }

      all_checkouts.concat(checkouts)
      all_holds.concat(holds)

      # Track item transitions and snapshot using ItemTracker.
      # Order matters: detect_transitions compares against the latest stored
      # snapshot, so it must run before this scrape is recorded.
      scraped_at = Time.now.iso8601
      @item_tracker.detect_transitions(checkouts, holds, patron[:name], scraped_at)
      @item_tracker.record_snapshot(checkouts, holds, patron[:name], scraped_at)

      # BiblioCommons intermittently serves an incomplete list, so an item
      # absent from one scrape has usually not actually gone anywhere. Keep
      # recently-missing items on the page, flagged, and only drop them once
      # they have been absent for MISSING_SCRAPES_BEFORE_REMOVAL scrapes.
      all_checkouts.concat(retained_missing(previous_checkouts, checkouts, patron[:name]))
      all_holds.concat(retained_missing(previous_holds, holds, patron[:name]))

      unexpected_count = @item_tracker.get_unexpected_transitions(1).count { |t| t["patron_name"] == patron[:name] }

      @data_store.save_checkouts(all_checkouts)
      @data_store.save_holds(all_holds)

      @data_store.log_scrape_attempt(
        patron[:name],
        true,
        {
          checkouts: checkouts.length,
          holds: holds.length,
          unexpected_transitions: unexpected_count
        }
      )

      data_store_elapsed = Time.now - data_store_start
      patron_elapsed = Time.now - patron_start_time

      @logger.info "Data store updated in #{format_duration(data_store_elapsed)}"
      @logger.info "\n" + "█" * 80
      @logger.info "█ PATRON SCRAPE COMPLETE: #{patron[:name]}"
      @logger.info "█ Checkouts: #{checkouts.length} | Holds: #{holds.length} | Unexpected: #{unexpected_count}"
      @logger.info "█ Total time: #{format_duration(patron_elapsed)}"
      @logger.info "█" * 80
    ensure
      # Only the context: the browser belongs to the caller and is reused.
      context.close
    end
  end

  def login_to_library(page, patron)
    library_url = ENV["LIBRARY_URL"]
    raise "LIBRARY_URL environment variable not set" unless library_url

    # Navigate directly to the login page instead of clicking through
    login_url = "#{library_url}/user/login"
    @logger.debug "Navigating directly to login page: #{login_url}"
    page.goto(login_url)

    # No fixed wait here: the username selector loop below already waits for
    # the field to appear, and page.goto has returned by this point.

    # Debug: Log the current page title and URL to see where we are
    @logger.debug "Current page title: #{page.title}"
    @logger.debug "Current URL: #{page.url}"

    # Debug: Get all input fields on the page
    inputs = page.locator("input").all
    @logger.debug "Found #{inputs.length} input fields on the page"
    inputs.each_with_index do |input, index|
      input_type = begin
        input.get_attribute("type")
      rescue
        "unknown"
      end
      input_name = begin
        input.get_attribute("name")
      rescue
        "unknown"
      end
      input_id = begin
        input.get_attribute("id")
      rescue
        "unknown"
      end
      input_placeholder = begin
        input.get_attribute("placeholder")
      rescue
        "unknown"
      end
      @logger.debug "Input #{index + 1}: type=#{input_type}, name=#{input_name}, id=#{input_id}, placeholder=#{input_placeholder}"
    end

    # Wait for login form to appear and find username field
    @logger.debug "Looking for username field"

    username_selectors = [
      'input[name="name"]',
      'input[type="text"]',
      "#user_name",
      "#name",
      'input[name="user_name"]'
    ]

    username_field = nil
    username_selectors.each do |selector|
      @logger.debug "Trying username selector: #{selector}"
      page.wait_for_selector(selector, timeout: 3000)
      username_field = selector
      @logger.debug "Found username field with selector: #{selector}"
      break
    rescue Playwright::TimeoutError
      @logger.debug "Username selector #{selector} not found, trying next..."
      next
    end

    unless username_field
      raise "Could not find username field with any of the attempted selectors"
    end

    # Fill in credentials
    @logger.debug "Filling in login credentials"
    page.fill(username_field, patron[:username])
    page.fill(PASSWORD_SELECTOR, patron[:password])

    # Submit login form
    @logger.debug "Submitting login form"
    page.click(LOGIN_BUTTON_SELECTOR)

    # Wait for login to complete - check if we're redirected away from login page
    @logger.debug "Waiting for login to complete..."

    begin
      # Wait for page to navigate away from login page (indicates successful login)
      page.wait_for_url(/^(?!.*\/user\/login).*/, timeout: 15000)
      @logger.debug "Login successful - redirected from login page"
      @logger.debug "New URL: #{page.url}"
    rescue Playwright::TimeoutError
      current_url = page.url
      @logger.debug "Current URL after login attempt: #{current_url}"
      if current_url.include?("/user/login")
        raise "Login failed - still on login page. Check credentials."
      else
        @logger.debug "Login appears successful but timeout waiting for redirect"
      end
    end
  end

  def scrape_checkouts(page, patron_name)
    overall_start_time = Time.now
    @logger.info "=" * 80
    @logger.info "Starting checkout scrape for #{patron_name}"
    @logger.info "=" * 80

    # Navigate to checkouts page
    checkout_url = ENV["LIBRARY_URL"] + CHECKOUTS_PAGE_PATH
    @logger.debug "Navigating to checkouts page: #{checkout_url}"
    page.goto(checkout_url)

    # No fixed wait here: page.goto has already returned, and the loop below
    # waits for the item container on every page including this one.

    @logger.debug "Checkouts page title: #{page.title}"
    @logger.debug "Checkouts page URL: #{page.url}"

    all_checkouts = []
    current_page = 1
    total_items_processed = 0
    seen_fingerprints = Set.new

    loop do
      page_start_time = Time.now
      @logger.info "\n--- Processing checkouts page #{current_page} ---"

      # Find checkout items using the correct selectors
      begin
        page.wait_for_selector(CHECKOUTS_CONTAINER_SELECTOR, timeout: CONTAINER_TIMEOUT_MS)
        checkout_items = page.locator(CHECKOUT_ITEM_SELECTOR).all
        @logger.info "Found #{checkout_items.length} checkout items on page #{current_page}"
        dump_page_html(page, "checkouts_page#{current_page}")
      rescue Playwright::TimeoutError
        # Page 1 timing out can legitimately mean "no checkouts at all", but
        # losing a later page means the list we have is truncated.
        if current_page > 1
          raise IncompleteScrapeError,
            "Checkouts page #{current_page} did not load for #{patron_name}; " \
            "collected #{all_checkouts.length} items before the failure"
        end

        @logger.warn "No checkouts container found on page #{current_page}"
        break
      end

      page_checkouts = []

      checkout_items.each_with_index do |item, index|
        item_start_time = Time.now
        item_number = total_items_processed + index + 1

        begin
          @logger.info "Processing checkout item #{item_number} (page #{current_page}, item #{index + 1}/#{checkout_items.length})..."

          # Use the precise selectors identified from the HTML structure
          title = extract_text_with_fallback(item, [TITLE_SELECTOR, ".title-content", ".cp-title a"])
          subtitle = extract_text_with_fallback(item, [SUBTITLE_SELECTOR])
          author = extract_text_with_fallback(item, [AUTHOR_SELECTOR, ".cp-author-link", ".author-link"])
          due_date = extract_text_with_fallback(item, [DUE_DATE_SELECTOR])

          # Extract and normalize item type (remove year info like "eBook, 2025" -> "eBook")
          raw_type = extract_text_with_fallback(item, [TYPE_SELECTOR]) || "Book"
          item_type = normalize_item_type(raw_type)

          item_elapsed = Time.now - item_start_time
          @logger.info "  ✓ #{item_type}: '#{title}' by #{author || "(no author)"} - due #{due_date} (#{format_duration(item_elapsed)})"

          # Check if item is renewable (this selector might not exist on all library systems)
          renewable = begin
            item.locator(RENEWABLE_SELECTOR).count > 0
          rescue
            false
          end

          # How many times this item has auto-renewed. BiblioCommons omits the
          # element entirely until an item has renewed at least once.
          renewal_count = parse_leading_count(
            extract_text_with_fallback(item, [RENEW_COUNT_SELECTOR])
          )

          # Other patrons holding this title. An item with anyone waiting will
          # not auto-renew, so this matters even when renewals remain.
          people_waiting = parse_leading_count(
            extract_text_with_fallback(item, [HELD_COPIES_SELECTOR])
          )

          # Get thumbnail URL if available
          thumbnail_url = begin
            img_locator = item.locator(THUMBNAIL_SELECTOR)
            # Check if thumbnail exists first to avoid timeout
            if img_locator.count > 0
              img_locator.first.get_attribute("src", timeout: 1000)
            end
          rescue
            nil
          end

          # Generate a unique ID for this item (used for thumbnail storage)
          item_id = generate_item_id(title, author, patron_name)

          # Download and save thumbnail if we have a URL
          if thumbnail_url && !@data_store.thumbnail_exists?(item_id)
            @logger.debug "    Downloading thumbnail..."
            download_thumbnail(thumbnail_url, item_id)
          end

          checkout = {
            "title" => title,
            "subtitle" => subtitle,
            "author" => author,
            "due_date" => parse_due_date(due_date),
            "type" => item_type,
            "renewable" => renewable,
            "renewal_count" => renewal_count,
            "people_waiting" => people_waiting,
            "patron_name" => patron_name,
            "thumbnail_url" => thumbnail_url ? "/thumbnails/#{item_id}.jpg" : "/placeholder.jpg",
            "item_id" => item_id
          }

          page_checkouts << checkout if title && !title.empty?
        rescue => e
          item_elapsed = Time.now - item_start_time
          @logger.warn "  ✗ Failed to parse checkout item #{item_number}: #{e.message} (#{format_duration(item_elapsed)})"
        end
      end

      # Stop before recording anything if this page repeats the previous one.
      # BiblioCommons serves page 1 for out-of-range page numbers, so without
      # this the loop would keep collecting duplicates forever.
      fingerprint = page_fingerprint(page_checkouts)
      if seen_fingerprints.include?(fingerprint)
        @logger.warn "Page #{current_page} repeats an earlier page; stopping checkout pagination"
        break
      end
      seen_fingerprints << fingerprint

      all_checkouts.concat(page_checkouts)
      total_items_processed += checkout_items.length

      page_elapsed = Time.now - page_start_time
      @logger.info "Page #{current_page} complete: #{page_checkouts.length} items processed in #{format_duration(page_elapsed)}"
      @logger.info "Total checkouts collected so far: #{all_checkouts.length}"

      # Check for next page
      if current_page >= MAX_PAGES
        @logger.warn "Reached page cap (#{MAX_PAGES}); stopping checkout pagination"
        break
      elsif has_next_page?(page, current_page)
        current_page += 1
        next_page_url = "#{checkout_url}?page=#{current_page}"
        @logger.debug "Navigating to next page: #{next_page_url}"
        page.goto(next_page_url)
        sleep(self.class.page_settle_seconds)
      else
        @logger.debug "No more pages found, stopping pagination"
        break
      end
    end

    overall_elapsed = Time.now - overall_start_time
    avg_time_per_item = (all_checkouts.length > 0) ? overall_elapsed / all_checkouts.length : 0

    @logger.info "\n" + "=" * 80
    @logger.info "Checkout scrape complete for #{patron_name}"
    @logger.info "Total items: #{all_checkouts.length}"
    @logger.info "Total time: #{format_duration(overall_elapsed)}"
    @logger.info "Average time per item: #{format_duration(avg_time_per_item)}"
    @logger.info "=" * 80

    all_checkouts
  end

  def scrape_holds(page, patron_name)
    overall_start_time = Time.now
    @logger.info "\n" + "=" * 80
    @logger.info "Starting holds scrape for #{patron_name}"
    @logger.info "=" * 80

    # Navigate to holds page
    holds_url = ENV["LIBRARY_URL"] + HOLDS_PAGE_PATH
    @logger.debug "Navigating to holds page: #{holds_url}"
    page.goto(holds_url)

    # No fixed wait here; see scrape_checkouts.

    @logger.debug "Holds page title: #{page.title}"
    @logger.debug "Holds page URL: #{page.url}"

    all_holds = []
    current_page = 1
    total_items_processed = 0
    seen_fingerprints = Set.new

    loop do
      page_start_time = Time.now
      @logger.info "\n--- Processing holds page #{current_page} ---"

      # Find hold items using the correct selectors
      begin
        page.wait_for_selector(HOLDS_CONTAINER_SELECTOR, timeout: CONTAINER_TIMEOUT_MS)
        hold_items = page.locator(HOLD_ITEM_SELECTOR).all
        dump_page_html(page, "holds_page#{current_page}")
        @logger.info "Found #{hold_items.length} hold items on page #{current_page}"
      rescue Playwright::TimeoutError
        if current_page > 1
          raise IncompleteScrapeError,
            "Holds page #{current_page} did not load for #{patron_name}; " \
            "collected #{all_holds.length} items before the failure"
        end

        @logger.warn "No holds container found on page #{current_page}"
        break
      end

      page_holds = []

      hold_items.each_with_index do |item, index|
        item_start_time = Time.now
        item_number = total_items_processed + index + 1

        begin
          @logger.info "Processing hold item #{item_number} (page #{current_page}, item #{index + 1}/#{hold_items.length})..."

          # Extract title, author, and status using correct selectors
          title = extract_text_with_fallback(item, [HOLD_TITLE_SELECTOR, TITLE_SELECTOR, ".cp-title a"])
          subtitle = extract_text_with_fallback(item, [SUBTITLE_SELECTOR])
          author = extract_text_with_fallback(item, [HOLD_AUTHOR_SELECTOR, ".cp-author-link a"])
          status = extract_text_with_fallback(item, [HOLD_STATUS_SELECTOR])

          # Extract and normalize item type (same as checkouts)
          raw_type = extract_text_with_fallback(item, [HOLD_TYPE_SELECTOR, TYPE_SELECTOR]) || "Book"
          item_type = normalize_item_type(raw_type)

          # Get checkout by date if available (for ready holds - physical or electronic)
          checkout_by = begin
            date_element = item.locator(CHECKOUT_BY_DATE_SELECTOR)
            if date_element.count > 0
              date_text = date_element.text_content(timeout: 1000)&.strip
              parse_due_date(date_text) if date_text && !date_text.empty?
            end
          rescue => e
            @logger.debug "    Could not extract checkout_by date: #{e.message}"
            nil
          end

          # Get hold expiry date if available (when the hold will expire/be suspended)
          expires_on = begin
            date_element = item.locator(HOLD_EXPIRY_DATE_SELECTOR)
            if date_element.count > 0
              date_text = date_element.text_content(timeout: 1000)&.strip
              parse_due_date(date_text) if date_text && !date_text.empty?
            end
          rescue => e
            @logger.debug "    Could not extract expires_on date: #{e.message}"
            nil
          end

          # Get queue position if available
          # Position format: "<strong>#1</strong> on 1 copies" or empty for ready holds
          position = begin
            pos_element = item.locator(POSITION_SELECTOR)
            # Use count to check if element exists without waiting
            if pos_element.count > 0
              pos_text = pos_element.text_content(timeout: 1000)&.strip
              # Extract first number from text like "#1 on 1 copies" or "Position 3 of 15"
              if pos_text && !pos_text.empty?
                pos_text.match(/\d+/)&.to_s&.to_i
              else
                nil  # Empty position (hold is ready)
              end
            end
          rescue => e
            @logger.debug "    Could not extract position: #{e.message}"
            nil
          end

          # Get thumbnail URL if available
          thumbnail_url = begin
            img_locator = item.locator(HOLD_THUMBNAIL_SELECTOR)
            # Check if thumbnail exists first to avoid timeout
            if img_locator.count > 0
              img_locator.first.get_attribute("src", timeout: 1000)
            end
          rescue
            nil
          end

          # Generate a unique ID for this item
          item_id = generate_item_id(title, author, patron_name)

          # Download and save thumbnail if we have a URL
          if thumbnail_url && !@data_store.thumbnail_exists?(item_id)
            @logger.debug "    Downloading thumbnail..."
            download_thumbnail(thumbnail_url, item_id)
          end

          hold = {
            "title" => title,
            "subtitle" => subtitle,
            "author" => author,
            "type" => item_type,
            "status" => status,
            "queue_position" => position,
            "checkout_by" => checkout_by,
            "expires_on" => expires_on,
            "patron_name" => patron_name,
            "thumbnail_url" => thumbnail_url ? "/thumbnails/#{item_id}.jpg" : "/placeholder.jpg",
            "item_id" => item_id
          }

          page_holds << hold if title && !title.empty?

          item_elapsed = Time.now - item_start_time
          position_text = position ? " (position #{position})" : ""
          checkout_text = checkout_by ? " - checkout by #{checkout_by}" : ""
          expires_text = expires_on ? " - expires #{expires_on}" : ""
          @logger.info "  ✓ #{item_type}: '#{title}' by #{author || "(no author)"} - #{status}#{position_text}#{checkout_text}#{expires_text} (#{format_duration(item_elapsed)})"
        rescue => e
          item_elapsed = Time.now - item_start_time
          @logger.warn "  ✗ Failed to parse hold item #{item_number}: #{e.message} (#{format_duration(item_elapsed)})"
        end
      end

      # Stop before recording anything if this page repeats the previous one.
      # BiblioCommons serves page 1 for out-of-range page numbers, so without
      # this the loop would keep collecting duplicates forever.
      fingerprint = page_fingerprint(page_holds)
      if seen_fingerprints.include?(fingerprint)
        @logger.warn "Page #{current_page} repeats an earlier page; stopping holds pagination"
        break
      end
      seen_fingerprints << fingerprint

      all_holds.concat(page_holds)
      total_items_processed += hold_items.length

      page_elapsed = Time.now - page_start_time
      @logger.info "Page #{current_page} complete: #{page_holds.length} items processed in #{format_duration(page_elapsed)}"
      @logger.info "Total holds collected so far: #{all_holds.length}"

      # Check for next page
      if current_page >= MAX_PAGES
        @logger.warn "Reached page cap (#{MAX_PAGES}); stopping holds pagination"
        break
      elsif has_next_page?(page, current_page)
        current_page += 1
        next_page_url = "#{holds_url}?page=#{current_page}"
        @logger.debug "Navigating to next page: #{next_page_url}"
        page.goto(next_page_url)
        sleep(self.class.page_settle_seconds)
      else
        @logger.debug "No more pages found, stopping pagination"
        break
      end
    end

    overall_elapsed = Time.now - overall_start_time
    avg_time_per_item = (all_holds.length > 0) ? overall_elapsed / all_holds.length : 0

    @logger.info "\n" + "=" * 80
    @logger.info "Holds scrape complete for #{patron_name}"
    @logger.info "Total items: #{all_holds.length}"
    @logger.info "Total time: #{format_duration(overall_elapsed)}"
    @logger.info "Average time per item: #{format_duration(avg_time_per_item)}"
    @logger.info "=" * 80

    all_holds
  end

  # Items the patron had that this scrape did not return, still within the
  # tolerance window. Each is tagged with how many scrapes have missed it so
  # the interface can mark it; once the count reaches the threshold the item
  # is left out and disappears from the page.
  def retained_missing(previous_items, current_items, patron_name)
    current_ids = current_items.map { |item| item["item_id"] }.to_set

    previous_items.reject { |item| current_ids.include?(item["item_id"]) }
      .filter_map do |item|
        missed = @item_tracker.missing_scrape_count(item["item_id"], patron_name)
        next if missed.zero? || missed >= self.class.missing_scrapes_before_removal

        plural = (missed == 1) ? "scrape" : "scrapes"
        @logger.info "  Keeping missing item (#{missed} #{plural}): #{item["title"]}"
        item.merge("missing_scrapes" => missed)
      end
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
      url = URI.join(ENV["LIBRARY_URL"], url).to_s unless url.start_with?("http")

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

  def extract_text_with_fallback(item, selectors)
    selectors.each do |selector|
      element = item.locator(selector)
      # Check if element exists first (fast operation)
      if element.count > 0
        # Element exists, get its text with a short timeout
        text = element.text_content(timeout: 1000)&.strip
        return text if text && !text.empty?
      end
    rescue => e
      @logger.debug "Selector '#{selector}' failed: #{e.message}"
      next
    end

    @logger.debug "All selectors failed for item, returning nil"
    nil
  end

  def extract_text_by_content_search(item, search_patterns, field_name)
    search_patterns.each do |pattern|
      # Find elements that contain the specific text pattern
      matching_elements = item.locator(":has-text('#{pattern}')").all
      @logger.debug "Found #{matching_elements.length} elements containing '#{pattern}' for #{field_name}"

      matching_elements.each do |element|
        text = element.text_content&.strip
        if text && !text.empty?
          @logger.debug "#{field_name} candidate text: '#{text}'"
          return text
        end
      end
    rescue => e
      @logger.debug "Content search for '#{pattern}' failed: #{e.message}"
      next
    end

    @logger.debug "No content found for #{field_name} with patterns: #{search_patterns}"
    nil
  end

  def extract_longest_text_element(item, field_name)
    # Get all text-containing elements and find the longest meaningful one (likely the title)
    all_elements = item.locator("*").all
    longest_text = ""

    all_elements.each do |element|
      text = element.text_content&.strip
      # Skip empty text and very short text (likely labels)
      # Look for text that seems like a title (longer than 10 chars, not just numbers/dates)
      if text && text.length > 10 && text.length > longest_text.length &&
          !text.match(/^\d+$/) && !text.match(/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/) &&
          !text.include?("remaining") && !text.include?("days") && !text.include?("Due")
        longest_text = text
        @logger.debug "#{field_name} candidate (longer): '#{text[0..50]}...'"
      end
    rescue
      next
    end

    longest_text.empty? ? nil : longest_text
  rescue => e
    @logger.debug "Error extracting longest text for #{field_name}: #{e.message}"
    nil
  end

  def extract_author_text_element(item, field_name)
    # Look for text patterns that indicate author names (Last, First format is common)
    all_elements = item.locator("*").all

    all_elements.each do |element|
      text = element.text_content&.strip
      # Look for author patterns: "Last, First" or contains common author indicators
      if text && text.length > 3 && text.length < 100 &&
          text.include?(", ") && text.match(/^[A-Z][a-z]+(, [A-Z][a-z]+)?/) ||
          text.match(/^[A-Z][a-z]+ [A-Z][a-z]+$/)
        @logger.debug "#{field_name} candidate: '#{text}'"
        return text
      end
    rescue
      next
    end

    @logger.debug "No author pattern found for #{field_name}"
    nil
  rescue => e
    @logger.debug "Error extracting author for #{field_name}: #{e.message}"
    nil
  end

  # Build a stable fingerprint of the items on the current page.
  #
  # Used to detect the case where BiblioCommons stops serving new results for
  # ?page=N. Observed in the wild: a patron whose holds pages alternate between
  # two payloads (A/B/A/B...) forever, so comparing only against the previous
  # page never trips. Callers therefore track every fingerprint seen and stop
  # on any repeat, regardless of what the pagination controls claim.
  # Writes the raw HTML of the current page to DUMP_HTML_DIR, for capturing
  # fixtures from a real scrape. Inert unless the env var is set. The dumps
  # contain live account data and must be scrubbed before being shared.
  def dump_page_html(page, label)
    dir = ENV["DUMP_HTML_DIR"]
    return unless dir && !dir.empty?

    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{label}.html")
    File.write(path, page.content)
    @logger.info "Dumped page HTML to #{path}"
  rescue => e
    @logger.warn "Could not dump page HTML (#{label}): #{e.message}"
  end

  def page_fingerprint(items)
    items.map { |item| "#{item["title"]}|#{item["author"]}|#{item["item_id"]}" }.join("\n")
  end

  def has_next_page?(page, current_page)
    # Check for pagination controls and determine if there's a next page

    # Method 1: Check for enabled "Next" button (most reliable)
    next_button = page.locator(NEXT_BUTTON_SELECTOR)
    if next_button.count > 0
      @logger.debug "Found enabled 'Next' button, has next page"
      return true
    end

    # Method 2: Check data-page attributes for pages greater than current
    page_links = page.locator(PAGINATION_ITEM_SELECTOR).all
    @logger.debug "Found #{page_links.length} pagination page links"

    page_links.each do |link|
      data_page = link.get_attribute("data-page")
      if data_page
        page_num = data_page.to_i
        @logger.debug "  Page link: data-page=#{page_num}"
        if page_num > current_page
          @logger.debug "Found page #{page_num} > current page #{current_page}, has next page"
          return true
        end
      end
    rescue => e
      @logger.debug "Error checking page link: #{e.message}"
      next
    end

    # Method 3: Legacy fallback - check old selector
    pagination_items = page.locator(PAGINATION_SELECTOR).all
    if pagination_items.length > 0
      @logger.debug "Using legacy pagination selector, found #{pagination_items.length} items"

      pagination_items.each do |item|
        text = item.text_content&.strip&.downcase

        # Check for "Next" button
        if text&.include?("next") || text&.include?(">")
          @logger.debug "Found 'Next' button via legacy selector, has next page"
          return true
        end

        # Check for page numbers greater than current page
        if text&.match(/^\d+$/)
          page_num = text.to_i
          if page_num > current_page
            @logger.debug "Found page #{page_num} > current page #{current_page} via legacy selector"
            return true
          end
        end
      rescue => e
        @logger.debug "Error checking legacy pagination item: #{e.message}"
        next
      end
    end

    @logger.debug "No next page found in pagination controls"
    false
  rescue => e
    @logger.warn "Error checking for next page: #{e.message}"
    false
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
    cleaned_date = date_text.gsub(/^(due|expires?|return by)\s*/i, "").strip
    cleaned_date = cleaned_date.gsub(/\s*(renewal|overdue).*/i, "").strip

    # Bibliocommons date formats (most common first)
    date_formats = [
      "%b %d, %Y",     # Dec 15, 2024
      "%B %d, %Y",     # December 15, 2024
      "%m/%d/%Y",      # 12/15/2024
      "%m-%d-%Y",      # 12-15-2024
      "%Y-%m-%d",      # 2024-12-15
      "%d-%b-%y"      # 15-Dec-24
    ]

    date_formats.each do |format|
      parsed_date = Date.strptime(cleaned_date, format)
      return parsed_date.iso8601
    rescue Date::Error
      next
    end

    # If no format worked, try natural language parsing
    begin
      require "date"
      parsed_date = Date.parse(cleaned_date)
      parsed_date.iso8601
    rescue Date::Error
      @logger.warn "Could not parse date: #{date_text} (cleaned: #{cleaned_date})"
      cleaned_date # Return original if parsing fails
    end
  end

  # Leading count out of a label like "Renewed 2 times" or "5 people waiting".
  # BiblioCommons omits these elements entirely rather than showing a zero, so
  # a missing label means none rather than unknown.
  def parse_leading_count(text)
    return 0 unless text

    match = text[/(\d+)/]
    match ? match.to_i : 0
  end

  def normalize_item_type(raw_type)
    return "Book" unless raw_type

    # ========================================
    # MEDIA TYPE NORMALIZATION
    # ========================================
    # Bibliocommons includes publication year in the type field:
    # - "Book, 2024" -> "Book"
    # - "eBook, 2025" -> "eBook"
    # - "DVD, 2025" -> "DVD"
    # - "Blu-ray Disc, 2025" -> "Blu-ray Disc"
    # - "Graphic Novel, 2018-" -> "Graphic Novel"
    # - "Board Game, 2021?" -> "Board Game"
    # ========================================

    # Extract media type (everything before the first comma)
    media_type = raw_type.split(",").first&.strip

    # Return normalized type or default to original if parsing fails
    (media_type && !media_type.empty?) ? media_type : raw_type
  end

  def format_duration(seconds)
    # Format duration in a human-readable way
    if seconds < 1
      "#{(seconds * 1000).round}ms"
    elsif seconds < 60
      "#{seconds.round(2)}s"
    else
      minutes = (seconds / 60).floor
      remaining_seconds = (seconds % 60).round
      "#{minutes}m #{remaining_seconds}s"
    end
  end
end
