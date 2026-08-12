require_relative "test_helper"
require "logger"
require "library_scraper"

# Parses saved BiblioCommons markup with the scraper's real selectors, driving
# a headless browser over a file:// URL. No network and no login: the fixtures
# in test/fixtures are scrubbed captures of real pages.
#
# These are the tests that notice when BiblioCommons changes its markup --
# a selector that stops matching fails here rather than silently returning
# empty scrapes in production.
#
# Skipped when the Playwright browser is unavailable (e.g. a CI runner without
# `playwright install chromium`), so the rest of the suite still runs.
class TestScraperExtraction < Minitest::Test
  include TempDataDir

  FIXTURE_DIR = File.expand_path("fixtures", __dir__)

  class << self
    attr_accessor :playwright_available
  end

  def setup
    super
    @store = DataStore.new(@tmp_dir)
    @scraper = LibraryScraper.new(@store, Logger.new(File::NULL))
  end

  def teardown
    @scraper.instance_variable_get(:@item_tracker)&.close
    super
  end

  # Loads a fixture in a real browser and yields the page.
  def with_fixture(name)
    skip "Playwright browser not available" unless browser_available?

    Playwright.create(playwright_cli_executable_path: "npx playwright") do |playwright|
      playwright.chromium.launch(headless: true) do |browser|
        page = browser.new_page
        page.goto("file://#{File.join(FIXTURE_DIR, name)}")
        yield page
      end
    end
  end

  def browser_available?
    cls = self.class
    return cls.playwright_available unless cls.playwright_available.nil?

    cls.playwright_available = begin
      Playwright.create(playwright_cli_executable_path: "npx playwright") do |playwright|
        playwright.chromium.launch(headless: true) { |b| b.contexts }
      end
      true
    rescue => e
      warn "Playwright unavailable, skipping extraction tests: #{e.message}"
      false
    end
  end

  def checkout_items(page)
    page.locator(LibraryScraper::CHECKOUT_ITEM_SELECTOR).all
  end

  def test_fixture_matches_the_container_selector
    with_fixture("checkouts_page.html") do |page|
      assert_equal 1, page.locator(LibraryScraper::CHECKOUTS_CONTAINER_SELECTOR).count,
        "container selector should match the saved markup"
    end
  end

  def test_finds_every_checkout_item
    with_fixture("checkouts_page.html") do |page|
      assert_equal 4, checkout_items(page).length
    end
  end

  def test_extracts_checkout_titles
    with_fixture("checkouts_page.html") do |page|
      titles = checkout_items(page).map do |item|
        @scraper.send(:extract_text_with_fallback, item, [LibraryScraper::TITLE_SELECTOR])
      end

      assert_equal ["Moby-Dick", "Frankenstein", "Dracula", "Middlemarch"], titles
    end
  end

  def test_extracts_checkout_authors
    with_fixture("checkouts_page.html") do |page|
      authors = checkout_items(page).map do |item|
        @scraper.send(:extract_text_with_fallback, item, [LibraryScraper::AUTHOR_SELECTOR])
      end

      assert_equal ["Melville, Herman", "Shelley, Mary", "Stoker, Bram", "Eliot, George"], authors
    end
  end

  def test_extracts_and_normalises_item_type
    with_fixture("checkouts_page.html") do |page|
      raw = @scraper.send(
        :extract_text_with_fallback, checkout_items(page).first,
        [LibraryScraper::TYPE_SELECTOR]
      )

      # The markup carries "Graphic Novel, 2018-" style values; the scraper
      # strips the publication year.
      refute_nil raw
      assert_includes raw, ","
      assert_equal raw.split(",").first.strip, @scraper.send(:normalize_item_type, raw)
    end
  end

  def test_extracts_due_date_that_parses
    with_fixture("checkouts_page.html") do |page|
      raw = @scraper.send(
        :extract_text_with_fallback, checkout_items(page).first,
        [LibraryScraper::DUE_DATE_SELECTOR]
      )

      refute_nil raw, "due date selector should match the saved markup"
      parsed = @scraper.send(:parse_due_date, raw)
      assert_match(/^\d{4}-\d{2}-\d{2}$/, parsed,
        "real due date text #{raw.inspect} should parse to an ISO date")
    end
  end

  def test_finds_hold_items
    with_fixture("holds_page.html") do |page|
      assert_equal 2, page.locator(LibraryScraper::HOLD_ITEM_SELECTOR).all.length
    end
  end

  def test_extracts_hold_titles
    with_fixture("holds_page.html") do |page|
      titles = page.locator(LibraryScraper::HOLD_ITEM_SELECTOR).all.map do |item|
        @scraper.send(:extract_text_with_fallback, item, [LibraryScraper::HOLD_TITLE_SELECTOR])
      end

      assert_equal ["Emma", "Hard Times"], titles
    end
  end

  def test_extracts_hold_status
    with_fixture("holds_page.html") do |page|
      status = @scraper.send(
        :extract_text_with_fallback,
        page.locator(LibraryScraper::HOLD_ITEM_SELECTOR).all.first,
        [LibraryScraper::STATUS_SELECTOR]
      )

      assert_equal "Paused", status
    end
  end

  # The saved holds are paused, which ItemTracker maps to hold_paused. This ties
  # the real markup through to the state the tracker records.
  def test_hold_status_maps_to_tracker_state
    with_fixture("holds_page.html") do |page|
      status = @scraper.send(
        :extract_text_with_fallback,
        page.locator(LibraryScraper::HOLD_ITEM_SELECTOR).all.first,
        [LibraryScraper::STATUS_SELECTOR]
      )

      tracker = ItemTracker.new(File.join(@tmp_dir, "state"))
      state = tracker.send(:determine_hold_state, {"status" => status})
      tracker.close

      assert_equal "hold_paused", state
    end
  end

  def test_thumbnail_selector_matches
    with_fixture("checkouts_page.html") do |page|
      assert_operator checkout_items(page).first.locator(LibraryScraper::THUMBNAIL_SELECTOR).count,
        :>, 0, "thumbnail selector should match the saved markup"
    end
  end

  # has_next_page? against a page with no pagination controls: the fixtures are
  # single-page captures, so this exercises the real Playwright locator API
  # rather than the hand-written fakes in test_library_scraper.rb.
  def test_has_next_page_false_on_single_page_fixture
    with_fixture("checkouts_page.html") do |page|
      refute @scraper.send(:has_next_page?, page, 1)
    end
  end
end
