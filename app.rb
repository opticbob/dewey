require "dotenv/load"
require "sinatra"
require "sinatra/json"
require "rufus-scheduler"
require "json"
require "logger"
require "date"
require_relative "lib/data_store"
require_relative "lib/library_scraper"

class DeweyApp < Sinatra::Base
  configure do
    set :public_folder, "public"
    set :views, "views"
    enable :logging

    # Set up logger
    logger = Logger.new(STDOUT)
    logger.level = case ENV["LOG_LEVEL"]&.upcase
    when "DEBUG" then Logger::DEBUG
    when "WARN" then Logger::WARN
    when "ERROR" then Logger::ERROR
    else Logger::INFO
    end
    set :logger, logger
  end

  def initialize(app = nil)
    super
    @data_store = DataStore.new("data")
    @scraper = LibraryScraper.new(@data_store, settings.logger)
    start_scheduler
    run_initial_scrape
  end

  # Web Dashboard Routes
  get "/" do
    @data = @data_store.get_all_data
    erb :dashboard
  end

  get "/patron/:name" do
    patron_name = params[:name]
    @data = @data_store.get_patron_data(patron_name)
    @patron_name = patron_name
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
    json({
      missing_items_events: @data_store.get_missing_items_report,
      total_events: @data_store.get_missing_items_report.length
    })
  end

  get "/health" do
    json({
      status: "ok",
      timestamp: Time.now.iso8601,
      last_scrape: @data_store.get_last_scrape_time
    })
  end

  # Manual refresh endpoint
  post "/refresh" do
    Thread.new do
      @scraper.scrape_all_patrons
    end
    redirect "/"
  end

  # Helper methods for views
  helpers do
    def format_due_date(due_date_str)
      return "Unknown" unless due_date_str

      begin
        due_date = Time.parse(due_date_str)
        now = Time.now
        days_until_due = ((due_date - now) / 86400).to_i

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
        due_date = Time.parse(due_date_str)
        now = Time.now
        days_until_due = ((due_date - now) / 86400).to_i

        if days_until_due < 0
          "due-overdue"
        elsif days_until_due <= 3
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

      status_lower = status.downcase
      if status_lower.include?("ready") || status_lower.include?("available")
        "status-ready"
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
  end

  private

  def start_scheduler
    scheduler = Rufus::Scheduler.new
    interval = ENV.fetch("SCRAPE_INTERVAL", "1").to_i

    scheduler.every "#{interval}h" do
      settings.logger.info "Starting scheduled scrape"
      @scraper.scrape_all_patrons
    end

    # Also run every day at 6 AM to catch any overnight changes
    scheduler.cron "0 6 * * *" do
      settings.logger.info "Starting daily 6 AM scrape"
      @scraper.scrape_all_patrons
    end
  end

  def run_initial_scrape
    Thread.new do
      sleep 5 # Give the app time to start up
      settings.logger.info "Running initial scrape on startup"
      @scraper.scrape_all_patrons
    end
  end
end

if __FILE__ == $0
  DeweyApp.run!
end
