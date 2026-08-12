require "dotenv/load"
require "sinatra"
require "sinatra/json"
require "rufus-scheduler"
require "json"
require "logger"
require "date"
require_relative "lib/data_store"
require_relative "lib/library_scraper"
require_relative "lib/item_tracker"

class DeweyApp < Sinatra::Base
  configure do
    set :public_folder, "public"
    set :views, "views"
    enable :logging

    # Set up logger
    logger = Logger.new($stdout)
    logger.level = case ENV["LOG_LEVEL"]&.upcase
    when "DEBUG" then Logger::DEBUG
    when "WARN" then Logger::WARN
    when "ERROR" then Logger::ERROR
    else Logger::INFO
    end
    set :logger, logger
  end

  # data_dir, the scraper and the scheduling flag are injectable so tests can
  # drive the app without a real data directory, background timers, or a live
  # scrape. Production keeps the previous behaviour via the defaults.
  #
  # The collaborators are class-level because Sinatra dups the instance for
  # every request: anything assigned to an instance variable here would be
  # rebuilt per request, and the scrape guard has to be shared across them.
  class << self
    attr_accessor :data_dir, :scraper_override, :scheduled
  end
  self.scheduled = true

  def initialize(app = nil)
    super
    @data_store = self.class.shared_data_store
    @item_tracker = self.class.shared_item_tracker
    @scraper = self.class.shared_scraper(settings.logger)

    return unless self.class.scheduled && !self.class.scheduler_started

    self.class.scheduler_started = true
    start_scheduler
    run_initial_scrape
  end

  class << self
    attr_accessor :scheduler_started

    def shared_data_store
      @shared_data_store ||= DataStore.new(data_dir || ENV.fetch("DATA_DIR", "data"))
    end

    def shared_item_tracker
      @shared_item_tracker ||= ItemTracker.new(shared_data_store.data_dir)
    end

    def shared_scraper(logger)
      @shared_scraper ||= scraper_override || LibraryScraper.new(shared_data_store, logger)
    end

    # The guard has to outlive the per-request instances.
    def scrape_mutex
      @scrape_mutex ||= Mutex.new
    end

    # Test hook: drop the memoised collaborators so the next instance rebuilds
    # them from the current data_dir / scraper_override.
    def reset_for_test!
      @shared_data_store = nil
      @shared_item_tracker = nil
      @shared_scraper = nil
      @scrape_mutex = nil
      @scheduler_started = nil
    end
  end

  # Run a scrape unless one is already in flight.
  #
  # Scrapes can outlast their scheduling interval (a slow patron can take many
  # minutes), and the startup scrape can still be running when the first
  # interval fires. Overlapping runs hammer BiblioCommons and get us throttled,
  # so a second concurrent attempt is skipped rather than queued.
  # Returns true if the scrape ran, false if one was already in flight.
  def run_scrape(reason)
    # Hold onto the mutex we actually locked, so the unlock cannot land on a
    # different object than the lock did.
    mutex = self.class.scrape_mutex

    unless mutex.try_lock
      settings.logger.warn "Skipping #{reason}: a scrape is already running"
      return false
    end

    begin
      settings.logger.info reason
      @scraper.scrape_all_patrons
    rescue => e
      # A scrape raising here would otherwise take down the scheduler thread
      # or the /refresh worker without a trace. Individual patron failures are
      # already handled inside scrape_all_patrons; this catches anything above
      # that, such as a failure to launch the browser at all.
      settings.logger.error "Scrape failed: #{e.class}: #{e.message}"
    ensure
      mutex.unlock if mutex.owned?
    end

    true
  end

  # True when a scrape is in flight. Only a hint for the UI -- by the time a
  # caller acts on it the answer may have changed, so run_scrape still has to
  # do the real check.
  def scrape_running?
    return true unless self.class.scrape_mutex.try_lock
    self.class.scrape_mutex.unlock
    false
  end

  # Web Dashboard Routes
  get "/" do
    @data = @data_store.get_all_data
    @scrape_failures = @data_store.get_recent_scrape_failures
    erb :dashboard
  end

  get "/patron/:name" do
    patron_name = params[:name]
    @data = @data_store.get_patron_data(patron_name)
    @patron_name = patron_name
    @scrape_failures = @data_store.get_recent_scrape_failures
    erb :patron
  end

  # Thumbnail serving
  get "/thumbnails/:filename" do
    filename = params[:filename]
    file_path = File.join("data", "thumbnails", filename)

    if File.exist?(file_path)
      content_type "image/jpeg"
      send_file file_path
    else
      send_file "public/placeholder.jpg"
    end
  end

  # API Routes for Home Assistant
  get "/api/status" do
    json @data_store.get_all_data
  end

  get "/api/patron/:name" do
    json @data_store.get_patron_data(params[:name])
  end

  get "/api/missing-items" do
    missing_events = @item_tracker.get_missing_items_report(30)
    json({
      missing_items_events: missing_events,
      total_events: missing_events.length
    })
  end

  get "/api/transitions" do
    days_back = params[:days]&.to_i || 7

    # NOTE: both branches are the same today - ItemTracker only exposes
    # unexpected transitions. The `unexpected` param is accepted for
    # forward compatibility until a get_all_transitions method exists.
    transitions = @item_tracker.get_unexpected_transitions(days_back)

    json({
      transitions: transitions,
      total: transitions.length,
      days_back: days_back
    })
  end

  get "/health" do
    json({
      status: "ok",
      timestamp: Time.now.iso8601,
      last_scrape: @data_store.get_last_scrape_time,
      scrape_running: scrape_running?
    })
  end

  # Manual refresh endpoint.
  #
  # Goes through run_scrape rather than calling the scraper directly, so a
  # manual refresh that lands while a scheduled scrape is running is skipped
  # instead of starting a second concurrent login. Two scrapes at once make
  # the library log us out mid-run, which showed up as spurious "Login failed"
  # and timeout errors.
  post "/refresh" do
    already_running = scrape_running?

    unless already_running
      Thread.new { run_scrape("Starting manual scrape") }
    end

    # The dashboard posts this as a plain form, so browsers get a redirect;
    # API callers get the outcome.
    if request.accept?("text/html") && !request.xhr?
      redirect "/"
    else
      status(already_running ? 409 : 202)
      json({
        status: already_running ? "already_running" : "started",
        message: already_running ? "A scrape is already in progress" : "Scrape started",
        timestamp: Time.now.iso8601
      })
    end
  end

  # Manual thumbnail cleanup endpoint
  post "/cleanup-thumbnails" do
    deleted = @data_store.cleanup_stale_thumbnails(@item_tracker)
    json({
      status: "ok",
      thumbnails_deleted: deleted,
      timestamp: Time.now.iso8601
    })
  end

  # Helper methods for views
  helpers do
    def format_due_date(due_date_str)
      return "Unknown" unless due_date_str

      begin
        due_date = Time.parse(due_date_str).to_date
        today = Date.today
        days_until_due = (due_date - today).to_i

        formatted_date = due_date.strftime("%b %d")

        if days_until_due < 0
          "#{formatted_date} (#{-days_until_due} days overdue)"
        elsif days_until_due == 0
          "#{formatted_date} (Today!)"
        elsif days_until_due == 1
          "#{formatted_date} (Tomorrow)"
        elsif days_until_due <= 7
          "#{formatted_date} (#{days_until_due} days)"
        else
          formatted_date
        end
      rescue
        due_date_str
      end
    end

    def due_date_class(due_date_str)
      return "due-normal" unless due_date_str

      begin
        due_date = Time.parse(due_date_str).to_date
        today = Date.today
        days_until_due = (due_date - today).to_i
        due_soon_threshold = ENV.fetch("DUE_SOON_DAYS", "5").to_i

        if days_until_due < 0
          "due-overdue"
        elsif days_until_due <= due_soon_threshold
          "due-soon"
        else
          "due-normal"
        end
      rescue
        "due-normal"
      end
    end

    def status_class(status)
      return "status-waiting" unless status

      status_lower = status.downcase.strip
      if status_lower == "ready" || status_lower == "available"
        "status-ready"
      elsif status_lower == "not ready"
        "status-not-ready"
      elsif status_lower.include?("transit") || status_lower.include?("shipping")
        "status-transit"
      else
        "status-waiting"
      end
    end

    def format_timestamp(timestamp_str)
      return "Unknown" unless timestamp_str

      begin
        timestamp = Time.parse(timestamp_str)
        timestamp.strftime("%B %d, %Y at %I:%M %p")
      rescue
        timestamp_str
      end
    end

    def relative_time(timestamp_str)
      return "never" unless timestamp_str

      begin
        timestamp = Time.parse(timestamp_str)
        seconds_ago = (Time.now - timestamp).to_i

        if seconds_ago < 60
          "#{seconds_ago} seconds ago"
        elsif seconds_ago < 3600
          minutes = seconds_ago / 60
          "#{minutes} #{(minutes == 1) ? "minute" : "minutes"} ago"
        elsif seconds_ago < 86400
          hours = seconds_ago / 3600
          "#{hours} #{(hours == 1) ? "hour" : "hours"} ago"
        else
          days = seconds_ago / 86400
          "#{days} #{(days == 1) ? "day" : "days"} ago"
        end
      rescue
        "unknown"
      end
    end
  end

  private

  def start_scheduler
    scheduler = Rufus::Scheduler.new
    interval = ENV.fetch("SCRAPE_INTERVAL", "1").to_i

    scheduler.every "#{interval}h", overlap: false do
      run_scrape("Starting scheduled scrape")
    end

    # Also run every day at 6 AM to catch any overnight changes
    scheduler.cron "0 6 * * *", overlap: false do
      run_scrape("Starting daily 6 AM scrape")
    end

    # Clean up stale thumbnails weekly on Sundays at 3 AM
    scheduler.cron "0 3 * * 0" do
      settings.logger.info "Starting weekly thumbnail cleanup"
      deleted = @data_store.cleanup_stale_thumbnails(@item_tracker)
      settings.logger.info "Thumbnail cleanup complete: #{deleted} thumbnails deleted"
    end
  end

  def run_initial_scrape
    Thread.new do
      sleep 5 # Give the app time to start up
      run_scrape("Running initial scrape on startup")
    end
  end
end

if __FILE__ == $0
  DeweyApp.run!
end
