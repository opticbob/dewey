require "json"
require "fileutils"
require "time"

class DataStore
  attr_reader :data_dir

  def initialize(data_dir = "data")
    @data_dir = data_dir
    ensure_data_directory
    ensure_thumbnail_directory
    initialize_data_files
  end

  def save_checkouts(checkouts)
    data = {
      checkouts: checkouts,
      last_updated: Time.now.iso8601
    }
    write_json_file("checkouts.json", data)
  end

  def save_holds(holds)
    data = {
      holds: holds,
      last_updated: Time.now.iso8601
    }
    write_json_file("holds.json", data)
  end

  def get_checkouts
    read_json_file("checkouts.json")&.dig("checkouts") || []
  end

  def get_holds
    read_json_file("holds.json")&.dig("holds") || []
  end

  def get_all_data
    checkouts_data = read_json_file("checkouts.json") || {}
    holds_data = read_json_file("holds.json") || {}

    checkouts = checkouts_data["checkouts"] || []
    holds = holds_data["holds"] || []

    {
      checkouts: sort_checkouts(checkouts),
      holds: sort_holds(holds),
      stats: calculate_stats(checkouts, holds),
      last_updated: [checkouts_data["last_updated"], holds_data["last_updated"]].compact.max
    }
  end

  def get_patron_data(patron_name)
    all_data = get_all_data

    checkouts = all_data[:checkouts].select { |item| item["patron_name"] == patron_name }
    holds = all_data[:holds].select { |item| item["patron_name"] == patron_name }

    {
      checkouts: checkouts,
      holds: holds,
      stats: calculate_stats(checkouts, holds),
      patron_name: patron_name,
      last_updated: all_data[:last_updated]
    }
  end

  def log_scrape_attempt(patron_name, success, items_scraped = {}, error_message = nil)
    log_entry = {
      timestamp: Time.now.iso8601,
      patron_name: patron_name,
      success: success,
      items_scraped: items_scraped,
      error_message: error_message
    }

    log_data = read_json_file("scrape_log.json") || {"scrapes" => []}
    log_data["scrapes"] << log_entry

    # Keep only last 100 log entries
    log_data["scrapes"] = log_data["scrapes"].last(100)

    write_json_file("scrape_log.json", log_data)
  end

  def track_missing_digital_items(current_checkouts, patron_name)
    # Get the previous scrape data for comparison
    previous_data = get_patron_historical_data(patron_name)
    return unless previous_data

    # Identify digital items from previous scrapes
    previous_digital_items = previous_data.select do |item|
      digital_types = ["eBook", "eAudiobook", "Digital"]
      item["type"] && digital_types.any? { |type| item["type"].include?(type) }
    end

    # Find current digital items
    current_digital_items = current_checkouts.select do |item|
      digital_types = ["eBook", "eAudiobook", "Digital"]
      item["type"] && digital_types.any? { |type| item["type"].include?(type) }
    end

    # Find missing digital items (were in previous scrape but not in current)
    missing_items = previous_digital_items.reject do |prev_item|
      current_digital_items.any? { |curr_item| curr_item["item_id"] == prev_item["item_id"] }
    end

    # Log missing digital items if any are found
    if missing_items.any?
      missing_log = {
        timestamp: Time.now.iso8601,
        patron_name: patron_name,
        missing_digital_items: missing_items.map do |item|
          {
            title: item["title"],
            author: item["author"],
            type: item["type"],
            item_id: item["item_id"],
            last_seen: previous_data.first&.dig("timestamp") || "unknown"
          }
        end,
        total_current_digital: current_digital_items.length,
        total_missing: missing_items.length
      }

      save_missing_items_log(missing_log)
    end

    missing_items
  end

  def save_missing_items_log(log_entry)
    log_data = read_json_file("missing_items_log.json") || {"missing_items_events" => []}
    log_data["missing_items_events"] << log_entry

    # Keep only last 50 missing item events
    log_data["missing_items_events"] = log_data["missing_items_events"].last(50)

    write_json_file("missing_items_log.json", log_data)
  end

  def get_patron_historical_data(patron_name, days_back = 1)
    # Get the last known checkout data for a patron from previous scrapes
    log_data = read_json_file("scrape_log.json")
    return [] unless log_data && log_data["scrapes"]

    # Find the most recent successful scrape for this patron
    cutoff_time = Time.now - (days_back * 24 * 60 * 60)

    recent_scrapes = log_data["scrapes"]
      .select { |scrape| scrape["patron_name"] == patron_name && scrape["success"] }
      .select { |scrape| Time.parse(scrape["timestamp"]) > cutoff_time }
      .sort_by { |scrape| scrape["timestamp"] }
      .reverse

    return [] if recent_scrapes.empty?

    # Try to get checkout data from around that time
    # For now, we'll use the current checkout data as a baseline
    # In a future enhancement, we could store historical snapshots
    checkouts_data = read_json_file("checkouts.json")
    return [] unless checkouts_data && checkouts_data["checkouts"]

    checkouts_data["checkouts"].select { |item| item["patron_name"] == patron_name }
  end

  def get_missing_items_report
    log_data = read_json_file("missing_items_log.json")
    return [] unless log_data && log_data["missing_items_events"]

    log_data["missing_items_events"]
  end

  def get_last_scrape_time
    log_data = read_json_file("scrape_log.json")
    return nil unless log_data && log_data["scrapes"]

    last_successful_scrape = log_data["scrapes"].reverse.find { |scrape| scrape["success"] }
    last_successful_scrape&.dig("timestamp")
  end

  def get_recent_scrape_failures
    log_data = read_json_file("scrape_log.json")
    return [] unless log_data && log_data["scrapes"]

    # Get scrapes from the last 24 hours
    cutoff_time = Time.now - (24 * 60 * 60)

    recent_failures = log_data["scrapes"]
      .select { |scrape| !scrape["success"] }
      .select do |scrape|
        begin
          Time.parse(scrape["timestamp"]) > cutoff_time
        rescue
          false
        end
      end
      .reverse # Most recent first

    recent_failures
  end

  def get_thumbnail_path(item_id)
    File.join(@data_dir, "thumbnails", "#{item_id}.jpg")
  end

  def save_thumbnail(item_id, image_data)
    thumbnail_path = get_thumbnail_path(item_id)
    File.binwrite(thumbnail_path, image_data)
    thumbnail_path
  end

  def thumbnail_exists?(item_id)
    File.exist?(get_thumbnail_path(item_id))
  end

  private

  def sort_checkouts(checkouts)
    # Sort by due date (earliest first)
    checkouts.sort_by do |item|
      begin
        Time.parse(item["due_date"])
      rescue
        Time.now + (365 * 24 * 60 * 60) # Put items with invalid dates at the end (1 year from now)
      end
    end
  end

  def sort_holds(holds)
    # Separate holds into three categories
    ready_holds = []
    active_holds = []
    paused_holds = []

    holds.each do |item|
      status = item["status"]&.downcase&.strip || ""
      # Check if item is ready (status is "ready" or "available", but NOT "not ready")
      if status == "ready" || status == "available"
        ready_holds << item
      elsif status == "paused"
        paused_holds << item
      else
        active_holds << item
      end
    end

    # Sort ready holds by checkout_by date (earliest deadline first)
    sorted_ready = ready_holds.sort_by do |item|
      deadline = item["checkout_by"] || item["expires_on"]
      if deadline
        begin
          Time.parse(deadline)
        rescue
          Time.now + (365 * 24 * 60 * 60) # Put items with invalid dates at the end
        end
      else
        Time.now + (365 * 24 * 60 * 60) # Put items without dates at the end
      end
    end

    # Sort active not-ready holds by queue position
    sorted_active = active_holds.sort_by do |item|
      item["queue_position"] || 999 # Put items without position at the end
    end

    # Sort paused holds by queue position
    sorted_paused = paused_holds.sort_by do |item|
      item["queue_position"] || 999 # Put items without position at the end
    end

    # Return ready holds first, then active holds, then paused holds
    sorted_ready + sorted_active + sorted_paused
  end

  def ensure_data_directory
    FileUtils.mkdir_p(@data_dir)
  end

  def ensure_thumbnail_directory
    FileUtils.mkdir_p(File.join(@data_dir, "thumbnails"))
  end

  def initialize_data_files
    %w[checkouts.json holds.json scrape_log.json missing_items_log.json].each do |filename|
      file_path = File.join(@data_dir, filename)
      next if File.exist?(file_path)

      initial_data = case filename
      when "checkouts.json"
        {checkouts: [], last_updated: nil}
      when "holds.json"
        {holds: [], last_updated: nil}
      when "scrape_log.json"
        {scrapes: []}
      when "missing_items_log.json"
        {missing_items_events: []}
      end

      write_json_file(filename, initial_data)
    end
  end

  def read_json_file(filename)
    file_path = File.join(@data_dir, filename)
    return nil unless File.exist?(file_path)

    JSON.parse(File.read(file_path))
  rescue JSON::ParserError => e
    puts "Error parsing JSON from #{filename}: #{e.message}"
    nil
  end

  def write_json_file(filename, data)
    file_path = File.join(@data_dir, filename)
    File.write(file_path, JSON.pretty_generate(data))
  end

  def calculate_stats(checkouts, holds)
    today = Date.today
    due_soon_days = ENV.fetch("DUE_SOON_DAYS", "5").to_i
    due_soon_threshold = today + due_soon_days

    items_overdue = checkouts.count do |item|
      due_date = Time.parse(item["due_date"]).to_date
      due_date < today
    rescue
      false
    end

    items_due_soon = checkouts.count do |item|
      due_date = Time.parse(item["due_date"]).to_date
      due_date <= due_soon_threshold
    rescue
      false
    end

    {
      total_checkouts: checkouts.length,
      total_holds: holds.length,
      items_overdue: items_overdue,
      items_due_soon: items_due_soon,
      due_soon_days: due_soon_days,
      patrons: (checkouts + holds).map { |item| item["patron_name"] }.uniq.compact.sort
    }
  end
end
