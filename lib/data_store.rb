require 'json'
require 'fileutils'
require 'time'

class DataStore
  attr_reader :data_dir

  def initialize(data_dir = 'data')
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
    write_json_file('checkouts.json', data)
  end

  def save_holds(holds)
    data = {
      holds: holds,
      last_updated: Time.now.iso8601
    }
    write_json_file('holds.json', data)
  end

  def get_checkouts
    read_json_file('checkouts.json')&.dig('checkouts') || []
  end

  def get_holds
    read_json_file('holds.json')&.dig('holds') || []
  end

  def get_all_data
    checkouts_data = read_json_file('checkouts.json') || {}
    holds_data = read_json_file('holds.json') || {}
    
    {
      checkouts: checkouts_data['checkouts'] || [],
      holds: holds_data['holds'] || [],
      stats: calculate_stats(checkouts_data['checkouts'] || [], holds_data['holds'] || []),
      last_updated: [checkouts_data['last_updated'], holds_data['last_updated']].compact.max
    }
  end

  def get_patron_data(patron_name)
    all_data = get_all_data
    
    checkouts = all_data[:checkouts].select { |item| item['patron_name'] == patron_name }
    holds = all_data[:holds].select { |item| item['patron_name'] == patron_name }
    
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

    log_data = read_json_file('scrape_log.json') || { 'scrapes' => [] }
    log_data['scrapes'] << log_entry
    
    # Keep only last 100 log entries
    log_data['scrapes'] = log_data['scrapes'].last(100)
    
    write_json_file('scrape_log.json', log_data)
  end

  def get_last_scrape_time
    log_data = read_json_file('scrape_log.json')
    return nil unless log_data && log_data['scrapes']
    
    last_successful_scrape = log_data['scrapes'].reverse.find { |scrape| scrape['success'] }
    last_successful_scrape&.dig('timestamp')
  end

  def get_thumbnail_path(item_id)
    File.join(@data_dir, 'thumbnails', "#{item_id}.jpg")
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

  def ensure_data_directory
    FileUtils.mkdir_p(@data_dir)
  end

  def ensure_thumbnail_directory
    FileUtils.mkdir_p(File.join(@data_dir, 'thumbnails'))
  end

  def initialize_data_files
    %w[checkouts.json holds.json scrape_log.json].each do |filename|
      file_path = File.join(@data_dir, filename)
      next if File.exist?(file_path)

      initial_data = case filename
                     when 'checkouts.json'
                       { checkouts: [], last_updated: nil }
                     when 'holds.json'
                       { holds: [], last_updated: nil }
                     when 'scrape_log.json'
                       { scrapes: [] }
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
    now = Time.now
    due_soon_threshold = now + (3 * 24 * 60 * 60) # 3 days from now
    
    items_due_soon = checkouts.count do |item|
      begin
        due_date = Time.parse(item['due_date'])
        due_date <= due_soon_threshold
      rescue
        false
      end
    end

    {
      total_checkouts: checkouts.length,
      total_holds: holds.length,
      items_due_soon: items_due_soon,
      patrons: (checkouts + holds).map { |item| item['patron_name'] }.uniq.compact
    }
  end
end