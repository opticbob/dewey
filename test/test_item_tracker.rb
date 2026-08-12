require_relative "test_helper"

class TestItemTracker < Minitest::Test
  include TempDataDir

  def setup
    super
    @tracker = ItemTracker.new(@tmp_dir)
  end

  # Runs a scrape the way the scraper does: detect transitions against the
  # stored snapshot first, then record the new snapshot.
  def scrape(checkouts, holds, patron_name: "Josh", scraped_at: Time.now.iso8601)
    @tracker.detect_transitions(checkouts, holds, patron_name, scraped_at)
    @tracker.record_snapshot(checkouts, holds, patron_name, scraped_at)
  end

  # Reads through a separate connection so the tests do not depend on
  # ItemTracker exposing its database handle.
  def query(sql)
    db = SQLite3::Database.new(@tracker.db_path)
    db.results_as_hash = true
    db.execute(sql)
  ensure
    db&.close
  end

  def transitions
    query("SELECT * FROM item_transitions ORDER BY id")
  end

  def test_creates_schema_on_first_use
    tables = query(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    ).map { |r| r["name"] }

    assert_includes tables, "item_snapshots"
    assert_includes tables, "item_transitions"
  end

  def test_first_scrape_records_no_transitions
    # With no prior snapshot there is nothing to compare against, so a first
    # scrape must not report every item as newly appeared.
    scrape([checkout(item_id: "1")], [hold(item_id: "2")])

    assert_empty transitions
  end

  def test_new_item_is_recorded_as_appeared
    scrape([checkout(item_id: "1")], [])
    scrape([checkout(item_id: "1"), checkout(item_id: "2")], [])

    appeared = transitions.select { |t| t["transition_type"] == "appeared" }
    assert_equal 1, appeared.length
    assert_equal "2", appeared.first["item_id"]
    assert_equal 1, appeared.first["is_expected"]
  end

  def test_item_still_present_records_no_transition
    scrape([checkout(item_id: "1")], [])
    scrape([checkout(item_id: "1")], [])

    assert_empty transitions
  end

  # Regression test for the bug fixed in 5031524: transitions were compared
  # against the scrape two runs back, so an item present the whole time was
  # reported as disappeared on the third scrape.
  def test_item_present_across_three_scrapes_never_disappears
    3.times { scrape([checkout(item_id: "1")], []) }

    assert_empty transitions.select { |t| t["transition_type"] == "disappeared" }
  end

  def test_hold_progressing_to_ready_is_expected
    scrape([], [hold(item_id: "h1", status: "not ready")])
    scrape([], [hold(item_id: "h1", status: "ready")])

    change = transitions.find { |t| t["transition_type"] == "state_change" }
    refute_nil change
    assert_equal "hold_waiting", change["from_state"]
    assert_equal "hold_ready", change["to_state"]
    assert_equal 1, change["is_expected"]
  end

  def test_ready_hold_disappearing_is_unexpected
    scrape([], [hold(item_id: "h1", status: "ready")])
    scrape([], [])

    gone = transitions.find { |t| t["transition_type"] == "disappeared" }
    refute_nil gone
    assert_equal 0, gone["is_expected"], "a ready hold vanishing should be flagged"
    assert_match(/ready/i, gone["notes"])
  end

  def test_waiting_hold_disappearing_is_expected
    # A hold cancelled while still in the queue is a normal user action.
    scrape([], [hold(item_id: "h1", status: "not ready")])
    scrape([], [])

    gone = transitions.find { |t| t["transition_type"] == "disappeared" }
    assert_equal 1, gone["is_expected"]
  end

  def test_checkout_returned_near_due_date_is_expected
    scrape([checkout(item_id: "1", due_date: (Date.today + 2).to_s)], [])
    scrape([], [])

    gone = transitions.find { |t| t["transition_type"] == "disappeared" }
    assert_equal 1, gone["is_expected"]
  end

  def test_checkout_vanishing_long_before_due_date_is_unexpected
    scrape([checkout(item_id: "1", due_date: (Date.today + 20).to_s)], [])
    scrape([], [])

    gone = transitions.find { |t| t["transition_type"] == "disappeared" }
    assert_equal 0, gone["is_expected"]
  end

  def test_transitions_are_scoped_per_patron
    # One patron's items must not look like disappearances to another patron.
    scrape([checkout(item_id: "1", patron_name: "Josh")], [], patron_name: "Josh")
    scrape([checkout(item_id: "2", patron_name: "Jett")], [], patron_name: "Jett")
    scrape([checkout(item_id: "1", patron_name: "Josh")], [], patron_name: "Josh")

    assert_empty transitions.select { |t| t["transition_type"] == "disappeared" }
  end

  def test_snapshot_ignores_items_belonging_to_another_patron
    @tracker.record_snapshot(
      [checkout(item_id: "1", patron_name: "Jett")], [], "Josh"
    )

    rows = query("SELECT * FROM item_snapshots")
    assert_empty rows, "items for a different patron should not be snapshotted"
  end

  def test_get_unexpected_transitions_returns_only_unexpected
    scrape([], [hold(item_id: "h1", status: "ready")])
    scrape([], [])

    unexpected = @tracker.get_unexpected_transitions(30)
    assert_equal 1, unexpected.length
    assert_equal "h1", unexpected.first["item_id"]
  end

  def test_get_recent_item_ids_includes_snapshotted_items
    scrape([checkout(item_id: "1")], [hold(item_id: "h1")])

    ids = @tracker.get_recent_item_ids(90)
    assert_includes ids, "1"
    assert_includes ids, "h1"
  end
end
