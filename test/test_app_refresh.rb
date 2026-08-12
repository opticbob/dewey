require_relative "test_helper"
require "rack/test"
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
