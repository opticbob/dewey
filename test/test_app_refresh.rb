require_relative "test_helper"
require "rack/test"

# Must be set before app.rb loads. Sinatra 4 enforces host authorization
# outside the test environment, and Rack::Test sends Host: example.org, so
# every request would come back 403. Locally this was masked by RACK_ENV
# being set to production in .env; CI has no .env and defaulted to
# development, where the check is active.
ENV["APP_ENV"] = "test"
ENV["RACK_ENV"] = "test"

require_relative "../app"

# app.rb requires dotenv/load, which repopulates the real credentials from the
# repo's .env. Clear them again so a test that somehow reaches the real scraper
# cannot log in to the live library.
ENV.keys.grep(/^PATRON_/).each { |k| ENV.delete(k) }
ENV["LIBRARY_URL"] = "https://library.invalid"

# Covers the concurrency guard around scrapes.
#
# /refresh used to call the scraper directly in a bare thread, bypassing the
# mutex that the scheduled runs go through, so a manual refresh landing during
# a scheduled scrape started a second concurrent login. The library logs the
# session out mid-run when that happens, which surfaced as spurious "Login
# failed" and timeout errors.
class TestAppRefresh < Minitest::Test
  include Rack::Test::Methods
  include TempDataDir

  def setup
    super
    @scraper = FakeScraper.new
    # Configured on the class, not the instance: Sinatra dups the app for every
    # request, so an instance variable set here would be replaced by the real
    # scraper on the first call -- which, when this was first written, launched
    # a browser and logged in to the live library.
    DeweyApp.reset_for_test!
    DeweyApp.data_dir = @tmp_dir
    DeweyApp.scraper_override = @scraper
    DeweyApp.scheduled = false
    @app = DeweyApp.new
  end

  def teardown
    DeweyApp.shared_item_tracker&.close
    DeweyApp.reset_for_test!
    DeweyApp.data_dir = nil
    DeweyApp.scraper_override = nil
    DeweyApp.scheduled = true
    super
  end

  attr_reader :app

  def test_health_reports_no_scrape_running_when_idle
    get "/health"

    assert_equal 200, last_response.status
    refute JSON.parse(last_response.body)["scrape_running"]
  end

  # --- rendered pages -----------------------------------------------------

  def test_stat_cards_link_to_their_tables_on_both_pages
    seed_items

    ["/", "/patron/Josh"].each do |path|
      get path

      assert_equal 200, last_response.status, "#{path} should render"
      assert_includes last_response.body, 'href="#checkouts"',
        "#{path} stat cards should link to the checkouts table"
      assert_includes last_response.body, 'href="#holds"',
        "#{path} stat cards should link to the holds table"
    end
  end

  # A patron's page shows only their own failures.
  def test_patron_page_shows_only_that_patrons_failures
    store = DeweyApp.shared_data_store
    store.log_scrape_attempt("Josh", false, {}, "josh-specific-error")
    store.log_scrape_attempt("Jett", false, {}, "jett-specific-error")

    get "/patron/Josh"
    assert_includes last_response.body, "josh-specific-error"
    refute_includes last_response.body, "jett-specific-error"

    get "/patron/Jett"
    assert_includes last_response.body, "jett-specific-error"
    refute_includes last_response.body, "josh-specific-error"
  end

  def test_dashboard_shows_every_patrons_failures
    store = DeweyApp.shared_data_store
    store.log_scrape_attempt("Josh", false, {}, "josh-specific-error")
    store.log_scrape_attempt("Jett", false, {}, "jett-specific-error")

    get "/"

    assert_includes last_response.body, "josh-specific-error"
    assert_includes last_response.body, "jett-specific-error"
  end

  # The failure list is collapsed behind a <details> so it does not push the
  # library data off the first screen.
  def test_scrape_failures_are_collapsed_by_default
    DeweyApp.shared_data_store.log_scrape_attempt("Josh", false, {}, "boom")

    get "/"

    assert_includes last_response.body, "<details class=\"alert-banner\">"
    refute_includes last_response.body, "<details class=\"alert-banner\" open"
  end

  # The control is a real anchor to #top, so it still works if the script
  # does not run; the JS only handles showing and hiding it.
  def test_back_to_top_link_is_present_with_an_anchor_target
    ["/", "/patron/Josh"].each do |path|
      get path

      assert_includes last_response.body, 'id="backToTop"', "#{path} should have the control"
      assert_includes last_response.body, 'href="#top"', "#{path} should link to the top anchor"
      assert_includes last_response.body, 'id="top"', "#{path} needs the anchor target"
    end
  end

  def test_no_failure_banner_when_there_are_no_failures
    get "/"

    # The class name also appears in the stylesheet, so assert on the element.
    refute_includes last_response.body, "<details class=\"alert-banner\""
  end

  def seed_items
    store = DeweyApp.shared_data_store
    store.save_checkouts([{
      "item_id" => "1", "patron_name" => "Josh", "title" => "Moby-Dick",
      "due_date" => (Date.today + 7).to_s, "type" => "Book"
    }])
    store.save_holds([{
      "item_id" => "h1", "patron_name" => "Josh", "title" => "Emma",
      "status" => "ready"
    }])
  end

  def test_refresh_starts_a_scrape_when_idle
    post "/refresh", {}, {"HTTP_ACCEPT" => "application/json"}

    assert_equal 202, last_response.status
    assert_equal "started", JSON.parse(last_response.body)["status"]
    @scraper.wait_for_start
    assert_equal 1, @scraper.calls
  end

  # The bug: a manual refresh during an in-flight scrape must not start a
  # second one.
  def test_refresh_is_rejected_while_a_scrape_is_running
    @scraper.block!
    post "/refresh", {}, {"HTTP_ACCEPT" => "application/json"}
    @scraper.wait_for_start

    post "/refresh", {}, {"HTTP_ACCEPT" => "application/json"}

    assert_equal 409, last_response.status
    assert_equal "already_running", JSON.parse(last_response.body)["status"]
    assert_equal 1, @scraper.calls, "the second refresh must not start a scrape"
  ensure
    @scraper.release!
  end

  def test_health_reports_a_running_scrape
    @scraper.block!
    post "/refresh", {}, {"HTTP_ACCEPT" => "application/json"}
    @scraper.wait_for_start

    get "/health"

    assert JSON.parse(last_response.body)["scrape_running"]
  ensure
    @scraper.release!
  end

  def test_refresh_works_again_after_the_previous_scrape_finishes
    @scraper.block!
    post "/refresh", {}, {"HTTP_ACCEPT" => "application/json"}
    @scraper.wait_for_start
    @scraper.release!
    @scraper.wait_for_finish
    # wait_for_finish returns from inside scrape_all_patrons' ensure, a moment
    # before run_scrape unlocks; wait for the guard itself to clear.
    wait_until { !DeweyApp.scrape_mutex.locked? }

    # The guard is released with the scrape, so a later refresh runs normally.
    post "/refresh", {}, {"HTTP_ACCEPT" => "application/json"}

    assert_equal 202, last_response.status
    @scraper.wait_for_start
    @scraper.wait_for_finish
    assert_equal 2, @scraper.calls
  end

  # The dashboard posts a plain HTML form, so a browser must still be redirected
  # rather than shown JSON.
  def test_browser_form_post_redirects
    post "/refresh", {}, {"HTTP_ACCEPT" => "text/html,application/xhtml+xml"}

    assert_equal 302, last_response.status
    assert_equal "/", URI(last_response.headers["Location"]).path
  end

  # A scrape that blows up entirely must release the lock, or every later
  # refresh would be rejected for the life of the process.
  def test_lock_is_released_when_a_scrape_raises
    @scraper.raise_error!
    post "/refresh", {}, {"HTTP_ACCEPT" => "application/json"}
    @scraper.wait_for_finish

    get "/health"
    refute JSON.parse(last_response.body)["scrape_running"],
      "a failed scrape must not leave the guard locked"
  end

  # Polls a condition rather than sleeping a fixed amount, so the tests do not
  # depend on thread scheduling.
  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    raise "condition not met within #{timeout}s" unless yield
  end

  # Stands in for LibraryScraper, with hooks to hold a scrape open so the
  # overlap case can be tested deterministically rather than by timing.
  class FakeScraper
    attr_reader :calls

    def initialize
      @calls = 0
      @mutex = Mutex.new
      @started = Queue.new
      @finished = Queue.new
      @gate = nil
      @raise = false
    end

    def block!
      @gate = Queue.new
    end

    def release!
      @gate&.close
      @gate = nil
    end

    def raise_error!
      @raise = true
    end

    def wait_for_start(n = 1)
      n.times { Timeout.timeout(5) { @started.pop } }
    end

    def wait_for_finish
      Timeout.timeout(5) { @finished.pop }
    end

    def scrape_all_patrons
      @mutex.synchronize { @calls += 1 }
      @started << :started
      gate = @gate
      gate&.pop # blocks until release! closes the queue
      raise "boom" if @raise
      nil
    ensure
      @finished << :finished
    end
  end
end
