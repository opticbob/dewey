require "sqlite3"
require "fileutils"
require "time"

class ItemTracker
  attr_reader :db_path

  def initialize(data_dir = "data")
    @data_dir = data_dir
    @db_path = File.join(@data_dir, "item_tracking.db")
    ensure_database
  end

  def ensure_database
    FileUtils.mkdir_p(@data_dir)
    is_new = !File.exist?(@db_path)

    @db = SQLite3::Database.new(@db_path)
    @db.results_as_hash = true

    if is_new
      create_schema
    end
  end

  def create_schema
    @db.execute_batch <<-SQL
      CREATE TABLE IF NOT EXISTS item_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id TEXT NOT NULL,
        patron_name TEXT NOT NULL,
        title TEXT,
        subtitle TEXT,
        author TEXT,
        item_type TEXT NOT NULL,
        format TEXT,
        state TEXT NOT NULL,
        due_date TEXT,
        checkout_by TEXT,
        expires_on TEXT,
        queue_position INTEGER,
        scraped_at TEXT NOT NULL,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_item_snapshots_item_id ON item_snapshots(item_id);
      CREATE INDEX IF NOT EXISTS idx_item_snapshots_patron ON item_snapshots(patron_name);
      CREATE INDEX IF NOT EXISTS idx_item_snapshots_scraped_at ON item_snapshots(scraped_at);

      CREATE TABLE IF NOT EXISTS item_transitions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id TEXT NOT NULL,
        patron_name TEXT NOT NULL,
        title TEXT,
        from_state TEXT,
        to_state TEXT,
        transition_type TEXT NOT NULL,
        is_expected BOOLEAN DEFAULT 1,
        notes TEXT,
        transitioned_at TEXT NOT NULL,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_item_transitions_item_id ON item_transitions(item_id);
      CREATE INDEX IF NOT EXISTS idx_item_transitions_patron ON item_transitions(patron_name);
      CREATE INDEX IF NOT EXISTS idx_item_transitions_type ON item_transitions(transition_type);
      CREATE INDEX IF NOT EXISTS idx_item_transitions_unexpected ON item_transitions(is_expected) WHERE is_expected = 0;
    SQL
  end

  # Record a snapshot of current items for a patron
  def record_snapshot(checkouts, holds, patron_name, scraped_at = Time.now.iso8601)
    # Convert checkouts to snapshots
    checkouts.each do |item|
      next unless item["patron_name"] == patron_name

      state = determine_checkout_state(item)

      @db.execute(
        "INSERT INTO item_snapshots (item_id, patron_name, title, subtitle, author, item_type, format, state, due_date, scraped_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [item["item_id"], patron_name, item["title"], item["subtitle"], item["author"], "checkout", item["type"], state, item["due_date"], scraped_at]
      )
    end

    # Convert holds to snapshots
    holds.each do |item|
      next unless item["patron_name"] == patron_name

      state = determine_hold_state(item)

      @db.execute(
        "INSERT INTO item_snapshots (item_id, patron_name, title, subtitle, author, item_type, format, state, checkout_by, expires_on, queue_position, scraped_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [item["item_id"], patron_name, item["title"], item["subtitle"], item["author"], "hold", item["type"], state, item["checkout_by"], item["expires_on"], item["queue_position"], scraped_at]
      )
    end
  end

  # Detect and record transitions for a patron
  def detect_transitions(checkouts, holds, patron_name, scraped_at = Time.now.iso8601)
    # Get the most recent previous snapshot for this patron
    previous_snapshots = get_previous_snapshots(patron_name)
    return if previous_snapshots.empty?

    current_items = build_current_items_map(checkouts, holds, patron_name)
    previous_items = previous_snapshots.group_by { |s| s["item_id"] }

    # Find items that disappeared
    previous_items.each do |item_id, snapshots|
      previous = snapshots.first
      current = current_items[item_id]

      if current.nil?
        # Item disappeared - determine if expected
        record_disappearance(previous, scraped_at)
      elsif previous["state"] != current[:state]
        # Item changed state
        record_state_change(previous, current, scraped_at)
      end
    end

    # Find items that appeared (new checkouts/holds)
    current_items.each do |item_id, current|
      unless previous_items.key?(item_id)
        record_appearance(current, scraped_at)
      end
    end
  end

  def get_unexpected_transitions(days_back = 30)
    cutoff = (Time.now - (days_back * 24 * 60 * 60)).iso8601

    @db.execute(
      "SELECT * FROM item_transitions WHERE is_expected = 0 AND transitioned_at > ? ORDER BY transitioned_at DESC",
      [cutoff]
    )
  end

  def get_missing_items_report(days_back = 30)
    cutoff = (Time.now - (days_back * 24 * 60 * 60)).iso8601

    transitions = @db.execute(
      "SELECT * FROM item_transitions WHERE transition_type = 'disappeared' AND is_expected = 0 AND transitioned_at > ? ORDER BY transitioned_at DESC",
      [cutoff]
    )

    # Group by event (same patron and time)
    events = []
    transitions.group_by { |t| [t["patron_name"], t["transitioned_at"]] }.each do |(patron, time), items|
      events << {
        timestamp: time,
        patron_name: patron,
        missing_items: items.map { |item|
          {
            title: item["title"],
            item_id: item["item_id"],
            from_state: item["from_state"],
            notes: item["notes"]
          }
        },
        total_missing: items.length
      }
    end

    events
  end

  def get_recent_item_ids(days_back = 90)
    cutoff = (Time.now - (days_back * 24 * 60 * 60)).iso8601

    @db.execute(
      "SELECT DISTINCT item_id FROM item_snapshots WHERE scraped_at > ?",
      [cutoff]
    ).map { |row| row["item_id"] }
  end

  private

  def determine_checkout_state(item)
    "checked_out"
  end

  def determine_hold_state(item)
    status = item["status"]&.downcase&.strip || ""

    case status
    when "ready", "available"
      "hold_ready"
    when "paused"
      "hold_paused"
    when /transit|shipping/
      "hold_transit"
    else
      "hold_waiting"
    end
  end

  def get_previous_snapshots(patron_name)
    # Get the most recent scrape time before now
    previous_scrape = @db.execute(
      "SELECT DISTINCT scraped_at FROM item_snapshots WHERE patron_name = ? ORDER BY scraped_at DESC LIMIT 1 OFFSET 1",
      [patron_name]
    ).first

    return [] unless previous_scrape

    @db.execute(
      "SELECT * FROM item_snapshots WHERE patron_name = ? AND scraped_at = ?",
      [patron_name, previous_scrape["scraped_at"]]
    )
  end

  def build_current_items_map(checkouts, holds, patron_name)
    items = {}

    checkouts.each do |item|
      next unless item["patron_name"] == patron_name
      items[item["item_id"]] = {
        item_id: item["item_id"],
        patron_name: patron_name,
        title: item["title"],
        item_type: "checkout",
        state: determine_checkout_state(item),
        due_date: item["due_date"],
        data: item
      }
    end

    holds.each do |item|
      next unless item["patron_name"] == patron_name
      items[item["item_id"]] = {
        item_id: item["item_id"],
        patron_name: patron_name,
        title: item["title"],
        item_type: "hold",
        state: determine_hold_state(item),
        checkout_by: item["checkout_by"],
        expires_on: item["expires_on"],
        data: item
      }
    end

    items
  end

  def record_disappearance(previous, scraped_at)
    is_expected, notes = analyze_disappearance(previous)

    @db.execute(
      "INSERT INTO item_transitions (item_id, patron_name, title, from_state, to_state, transition_type, is_expected, notes, transitioned_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [previous["item_id"], previous["patron_name"], previous["title"], previous["state"], nil, "disappeared", is_expected ? 1 : 0, notes, scraped_at]
    )
  end

  def record_state_change(previous, current, scraped_at)
    is_expected, notes = analyze_state_change(previous, current)

    @db.execute(
      "INSERT INTO item_transitions (item_id, patron_name, title, from_state, to_state, transition_type, is_expected, notes, transitioned_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [previous["item_id"], previous["patron_name"], previous["title"], previous["state"], current[:state], "state_change", is_expected ? 1 : 0, notes, scraped_at]
    )
  end

  def record_appearance(current, scraped_at)
    @db.execute(
      "INSERT INTO item_transitions (item_id, patron_name, title, from_state, to_state, transition_type, is_expected, notes, transitioned_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [current[:item_id], current[:patron_name], current[:title], nil, current[:state], "appeared", 1, "New item", scraped_at]
    )
  end

  def analyze_disappearance(previous)
    state = previous["state"]
    item_type = previous["item_type"]

    # Check if checkout was near due date (expected return)
    if item_type == "checkout" && previous["due_date"]
      begin
        due_date = Time.parse(previous["due_date"]).to_date
        days_until_due = (due_date - Date.today).to_i

        if days_until_due <= 3
          return [true, "Item returned near due date (#{days_until_due} days until due)"]
        elsif days_until_due < 0
          return [true, "Item returned after due date (#{-days_until_due} days overdue)"]
        end
      rescue
        # Continue to unexpected if date parsing fails
      end
    end

    # Check digital items - these disappear when auto-returned
    format = previous["format"] || ""
    if format.include?("eBook") || format.include?("eAudiobook") || format.include?("Digital")
      if item_type == "checkout"
        return [true, "Digital item auto-returned on due date"]
      elsif state == "hold_ready"
        return [false, "Digital hold disappeared while ready for checkout"]
      end
    end

    # Hold state transitions
    case state
    when "hold_ready"
      return [false, "Hold disappeared while ready for pickup"]
    when "hold_waiting"
      return [true, "Hold cancelled or expired while waiting"]
    when "hold_paused"
      return [true, "Paused hold cancelled"]
    when "hold_transit"
      return [true, "Hold in transit cancelled"]
    end

    # Default: unexpected disappearance
    [false, "Item disappeared unexpectedly"]
  end

  def analyze_state_change(previous, current)
    from = previous["state"]
    to = current[:state]

    # Expected transitions
    expected_transitions = {
      "hold_waiting" => ["hold_transit", "hold_ready", "hold_paused"],
      "hold_transit" => ["hold_ready"],
      "hold_ready" => ["checked_out"],
      "hold_paused" => ["hold_waiting"]
    }

    if expected_transitions[from]&.include?(to)
      return [true, "Normal state progression: #{from} → #{to}"]
    end

    # Unexpected state change
    [false, "Unexpected state change: #{from} → #{to}"]
  end

  def close
    @db.close if @db
  end
end
