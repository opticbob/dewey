require_relative "test_helper"
require "logger"
require "library_scraper"

# Covers the parts of LibraryScraper that do not need a browser: date parsing,
# type normalisation, item IDs, patron config, and the pagination guards.
#
# The methods under test are private, so they are called with `send` rather than
# widening the class's public API for the tests' benefit.
class TestLibraryScraper < Minitest::Test
  include TempDataDir

  def setup
    super
    @store = DataStore.new(@tmp_dir)
    # Logger output is noise in test runs; discard it.
    @scraper = LibraryScraper.new(@store, Logger.new(File::NULL))
  end

  def teardown
    @scraper.instance_variable_get(:@item_tracker)&.close
    super
  end

  def parse_due_date(text)
    @scraper.send(:parse_due_date, text)
  end

  def normalize_item_type(raw)
    @scraper.send(:normalize_item_type, raw)
  end

  # --- parse_due_date -----------------------------------------------------

  def test_parses_abbreviated_month_format
    assert_equal "2024-12-15", parse_due_date("Dec 15, 2024")
  end

  def test_parses_full_month_format
    assert_equal "2024-12-15", parse_due_date("December 15, 2024")
  end

  def test_parses_slash_separated_format
    assert_equal "2024-12-15", parse_due_date("12/15/2024")
  end

  def test_parses_iso_format
    assert_equal "2024-12-15", parse_due_date("2024-12-15")
  end

  def test_strips_due_prefix
    assert_equal "2024-12-15", parse_due_date("Due Dec 15, 2024")
  end

  def test_strips_expires_prefix
    assert_equal "2024-12-15", parse_due_date("Expires Dec 15, 2024")
  end

  def test_strips_trailing_renewal_text
    assert_equal "2024-12-15", parse_due_date("Dec 15, 2024 - renewal available")
  end

  def test_strips_trailing_overdue_text
    assert_equal "2024-12-15", parse_due_date("Dec 15, 2024 overdue")
  end

  def test_parses_dash_separated_format
    assert_equal "2024-12-15", parse_due_date("12-15-2024")
  end

  def test_parses_two_digit_year_format
    assert_equal "2024-12-15", parse_due_date("15-Dec-24")
  end

  def test_strips_return_by_prefix
    assert_equal "2024-12-15", parse_due_date("Return by 12/15/2024")
  end

  def test_strips_renewal_count_suffix
    assert_equal "2024-12-15", parse_due_date("Dec 15, 2024 - 2 renewals left")
  end

  def test_returns_nil_for_nil_input
    assert_nil parse_due_date(nil)
  end

  def test_empty_string_returns_empty_string
    assert_equal "", parse_due_date("")
  end

  # Documents the fallback: unparseable text is returned as-is (cleaned) rather
  # than raising, so a scrape is not lost over one bad date.
  def test_unparseable_date_is_returned_unchanged
    assert_equal "sometime next week", parse_due_date("sometime next week")
  end

  # --- normalize_item_type ------------------------------------------------

  def test_strips_year_from_type
    assert_equal "Book", normalize_item_type("Book, 2024")
    assert_equal "eBook", normalize_item_type("eBook, 2025")
    assert_equal "DVD", normalize_item_type("DVD, 2025")
  end

  def test_keeps_multi_word_types
    assert_equal "Blu-ray Disc", normalize_item_type("Blu-ray Disc, 2025")
    assert_equal "Graphic Novel", normalize_item_type("Graphic Novel, 2018-")
  end

  def test_type_without_year_is_unchanged
    assert_equal "Book", normalize_item_type("Book")
  end

  def test_nil_type_defaults_to_book
    assert_equal "Book", normalize_item_type(nil)
  end

  # --- parse_leading_count ------------------------------------------------

  def test_parses_singular_and_plural_renewal_labels
    assert_equal 1, @scraper.send(:parse_leading_count, "Renewed 1 time")
    assert_equal 2, @scraper.send(:parse_leading_count, "Renewed 2 times")
    assert_equal 4, @scraper.send(:parse_leading_count, "Renewed 4 times")
  end

  def test_parses_singular_and_plural_waiting_labels
    assert_equal 1, @scraper.send(:parse_leading_count, "1 person waiting")
    assert_equal 5, @scraper.send(:parse_leading_count, "5 people waiting")
  end

  # BiblioCommons leaves these elements out entirely rather than showing a
  # zero, so a missing label means none rather than unknown.
  def test_missing_label_counts_as_zero
    assert_equal 0, @scraper.send(:parse_leading_count, nil)
  end

  def test_unparseable_label_counts_as_zero
    assert_equal 0, @scraper.send(:parse_leading_count, "Renewed")
  end

  # --- generate_item_id ---------------------------------------------------

  def test_item_id_is_stable_for_same_inputs
    a = @scraper.send(:generate_item_id, "Dune", "Frank Herbert", "Josh")
    b = @scraper.send(:generate_item_id, "Dune", "Frank Herbert", "Josh")
    assert_equal a, b
  end

  def test_item_id_differs_per_patron
    # The same book held by two patrons must not collide, or one patron's item
    # would look like the other's in the tracker.
    josh = @scraper.send(:generate_item_id, "Dune", "Frank Herbert", "Josh")
    jett = @scraper.send(:generate_item_id, "Dune", "Frank Herbert", "Jett")
    refute_equal josh, jett
  end

  def test_item_id_is_case_insensitive
    lower = @scraper.send(:generate_item_id, "dune", "frank herbert", "josh")
    upper = @scraper.send(:generate_item_id, "DUNE", "FRANK HERBERT", "JOSH")
    assert_equal lower, upper
  end

  def test_item_id_differs_for_different_titles
    dune = @scraper.send(:generate_item_id, "Dune", "Frank Herbert", "Josh")
    other = @scraper.send(:generate_item_id, "Neuromancer", "Frank Herbert", "Josh")
    refute_equal dune, other
  end

  # --- page_fingerprint ---------------------------------------------------

  def test_fingerprint_matches_for_identical_pages
    items = [
      {"title" => "Dune", "author" => "Herbert", "item_id" => "a1"},
      {"title" => "Neuromancer", "author" => "Gibson", "item_id" => "b2"}
    ]

    assert_equal @scraper.send(:page_fingerprint, items),
      @scraper.send(:page_fingerprint, items.dup)
  end

  def test_fingerprint_differs_for_different_pages
    page1 = [{"title" => "Dune", "author" => "Herbert", "item_id" => "a1"}]
    page2 = [{"title" => "Neuromancer", "author" => "Gibson", "item_id" => "b2"}]

    refute_equal @scraper.send(:page_fingerprint, page1),
      @scraper.send(:page_fingerprint, page2)
  end

  def test_fingerprint_is_order_sensitive
    a = {"title" => "Dune", "author" => "Herbert", "item_id" => "a1"}
    b = {"title" => "Neuromancer", "author" => "Gibson", "item_id" => "b2"}

    refute_equal @scraper.send(:page_fingerprint, [a, b]),
      @scraper.send(:page_fingerprint, [b, a])
  end

  # --- get_patron_configs -------------------------------------------------

  def test_reads_consecutive_patrons_from_env
    with_patron_env(
      "PATRON_1_NAME" => "Josh", "PATRON_1_USER" => "ju", "PATRON_1_PASS" => "jp",
      "PATRON_2_NAME" => "Jett", "PATRON_2_USER" => "tu", "PATRON_2_PASS" => "tp"
    ) do
      patrons = @scraper.send(:get_patron_configs)

      assert_equal 2, patrons.length
      assert_equal %w[Josh Jett], patrons.map { |p| p[:name] }
      assert_equal "ju", patrons.first[:username]
    end
  end

  def test_stops_at_first_gap_in_numbering
    # PATRON_3 is skipped because the loop stops at the first missing name.
    with_patron_env(
      "PATRON_1_NAME" => "Josh",
      "PATRON_3_NAME" => "Autumn"
    ) do
      patrons = @scraper.send(:get_patron_configs)
      assert_equal ["Josh"], patrons.map { |p| p[:name] }
    end
  end

  def test_returns_empty_when_no_patrons_configured
    with_patron_env({}) do
      assert_empty @scraper.send(:get_patron_configs)
    end
  end

  # --- truncated scrapes --------------------------------------------------

  # Reproduces the production failure: page 1 loads, page 2 times out. Before
  # the guard the scrape returned page 1 only, and the tracker recorded every
  # item from the missing page as an unexpected disappearance. On 2026-08-12
  # this hit 21.7% of Josh's scrapes (the only patron with two pages).
  def test_checkouts_raises_when_a_later_page_fails
    with_library_url do
      page = PaginatedFailingPage.new(fail_from_page: 2)

      error = assert_raises(LibraryScraper::IncompleteScrapeError) do
        @scraper.send(:scrape_checkouts, page, "Josh")
      end
      assert_match(/page 2/i, error.message)
    end
  end

  def test_holds_raises_when_a_later_page_fails
    with_library_url do
      page = PaginatedFailingPage.new(fail_from_page: 2)

      assert_raises(LibraryScraper::IncompleteScrapeError) do
        @scraper.send(:scrape_holds, page, "Josh")
      end
    end
  end

  # A first-page timeout is not truncation: a patron with nothing checked out
  # legitimately has no container, and must not be reported as a failure.
  def test_empty_first_page_does_not_raise
    with_library_url do
      page = PaginatedFailingPage.new(fail_from_page: 1)

      assert_equal [], @scraper.send(:scrape_checkouts, page, "Josh")
    end
  end

  # --- retaining missing items --------------------------------------------

  # An item absent from one scrape is usually still there: BiblioCommons
  # sometimes serves a short list. Keep it on the page, flagged, until enough
  # scrapes have missed it.
  def test_missing_item_is_retained_and_flagged
    tracker = @scraper.instance_variable_get(:@item_tracker)
    previous = [checkout(item_id: "1", title: "Dune")]

    tracker.detect_transitions(previous, [], "Josh", "2026-08-13T01:00:00+00:00")
    tracker.record_snapshot(previous, [], "Josh", "2026-08-13T01:00:00+00:00")
    tracker.detect_transitions([], [], "Josh", "2026-08-13T02:00:00+00:00")
    tracker.record_snapshot([], [], "Josh", "2026-08-13T02:00:00+00:00")

    kept = @scraper.send(:retained_missing, previous, [], "Josh")

    assert_equal 1, kept.length
    assert_equal "Dune", kept.first["title"]
    assert_equal 1, kept.first["missing_scrapes"]
  end

  def test_missing_item_is_dropped_after_the_threshold
    tracker = @scraper.instance_variable_get(:@item_tracker)
    previous = [checkout(item_id: "1")]

    tracker.detect_transitions(previous, [], "Josh", "2026-08-13T01:00:00+00:00")
    tracker.record_snapshot(previous, [], "Josh", "2026-08-13T01:00:00+00:00")
    (2..4).each do |h|
      at = format("2026-08-13T%02d:00:00+00:00", h)
      tracker.detect_transitions([], [], "Josh", at)
      tracker.record_snapshot([], [], "Josh", at)
    end

    # Three scrapes have now missed it, which is the default threshold.
    assert_equal 3, tracker.missing_scrape_count("1", "Josh")
    assert_empty @scraper.send(:retained_missing, previous, [], "Josh")
  end

  def test_items_present_in_the_scrape_are_not_retained
    previous = [checkout(item_id: "1")]

    assert_empty @scraper.send(:retained_missing, previous, previous, "Josh")
  end

  # --- has_next_page? -----------------------------------------------------

  def test_has_next_page_true_when_next_button_present
    page = FakePage.new(next_button_count: 1)
    assert @scraper.send(:has_next_page?, page, 1)
  end

  def test_has_next_page_true_when_later_page_link_exists
    page = FakePage.new(page_links: %w[1 2 3])
    assert @scraper.send(:has_next_page?, page, 2)
  end

  def test_has_next_page_false_on_last_page
    page = FakePage.new(page_links: %w[1 2 3])
    refute @scraper.send(:has_next_page?, page, 3)
  end

  def test_has_next_page_false_without_pagination
    refute @scraper.send(:has_next_page?, FakePage.new, 1)
  end

  # The date-picker regression is covered in test_scraper_extraction.rb, where
  # a real browser can evaluate the scoped CSS selector against markup. The
  # fakes here match selector strings literally and cannot express scoping.

  # Failures while inspecting the page must not abort a scrape; the method
  # swallows errors and reports "no next page".
  def test_has_next_page_false_when_page_raises
    refute @scraper.send(:has_next_page?, RaisingPage.new, 1)
  end

  # --- format_duration ----------------------------------------------------

  def test_format_duration_uses_milliseconds_under_a_second
    assert_equal "500ms", @scraper.send(:format_duration, 0.5)
  end

  def test_format_duration_uses_seconds_under_a_minute
    assert_equal "5.25s", @scraper.send(:format_duration, 5.25)
  end

  def test_format_duration_uses_minutes_and_seconds
    assert_equal "2m 5s", @scraper.send(:format_duration, 125)
  end

  private

  # The scrape methods build URLs from LIBRARY_URL before touching the page.
  def with_library_url
    saved = ENV["LIBRARY_URL"]
    ENV["LIBRARY_URL"] = "https://example.test"
    yield
  ensure
    ENV["LIBRARY_URL"] = saved
  end

  # Sets only the given PATRON_* vars for the block, clearing any others that
  # the loaded .env may have provided.
  def with_patron_env(vars)
    saved = ENV.select { |k, _| k.start_with?("PATRON_") }
    saved.each_key { |k| ENV.delete(k) }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    vars.each_key { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  # Minimal stand-ins for the Playwright page/locator API surface that
  # has_next_page? touches: locator(), count, all, get_attribute, text_content.
  class FakeLocator
    def initialize(count: 0, elements: [])
      @count = count
      @elements = elements
    end

    attr_reader :count

    def all
      @elements
    end
  end

  class FakeLink
    def initialize(data_page: nil, text: nil)
      @data_page = data_page
      @text = text
    end

    def get_attribute(name)
      (name == "data-page") ? @data_page : nil
    end

    def text_content
      @text
    end
  end

  class FakePage
    def initialize(next_button_count: 0, page_links: [], legacy_items: [])
      @next_button_count = next_button_count
      @page_links = page_links
      @legacy_items = legacy_items
    end

    def locator(selector)
      case selector
      when LibraryScraper::NEXT_BUTTON_SELECTOR
        FakeLocator.new(count: @next_button_count)
      when LibraryScraper::PAGINATION_ITEM_SELECTOR
        FakeLocator.new(
          count: @page_links.length,
          elements: @page_links.map { |n| FakeLink.new(data_page: n) }
        )
      else
        FakeLocator.new(
          count: @legacy_items.length,
          elements: @legacy_items.map { |t| FakeLink.new(text: t) }
        )
      end
    end
  end

  class RaisingPage
    def locator(_selector)
      raise "page closed"
    end
  end

  # Serves one item on each page up to fail_from_page, then times out waiting
  # for the container -- the shape of the real partial-scrape failure.
  class PaginatedFailingPage
    def initialize(fail_from_page:)
      @fail_from_page = fail_from_page
      @current_page = 0
    end

    def wait_for_selector(_selector, **_opts)
      @current_page += 1
      raise Playwright::TimeoutError.new(message: "timed out") if @current_page >= @fail_from_page
      nil
    end

    def locator(_selector)
      # One item per page, with no sub-elements, so extraction yields nils and
      # the loop still records an entry.
      FakeLocator.new(count: 1, elements: [FakeItem.new])
    end

    def goto(_url)
      nil
    end

    def title
      "Checkouts"
    end

    def url
      "https://example.test/v2/checkedout"
    end
  end

  # An item whose sub-locators are all empty; enough for the scrape loop to
  # build a record without needing real markup.
  class FakeItem
    def locator(_selector)
      FakeLocator.new(count: 0, elements: [])
    end

    def text_content(**_opts)
      nil
    end

    def get_attribute(_name, **_opts)
      nil
    end
  end
end
