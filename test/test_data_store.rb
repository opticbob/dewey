require_relative "test_helper"

class TestDataStore < Minitest::Test
  include TempDataDir

  def setup
    super
    @store = DataStore.new(@tmp_dir)
  end

  def test_initializes_data_files_and_thumbnail_dir
    assert File.directory?(File.join(@tmp_dir, "thumbnails"))
    %w[checkouts.json holds.json scrape_log.json missing_items_log.json].each do |f|
      assert File.exist?(File.join(@tmp_dir, f)), "#{f} should be created"
    end
  end

  def test_empty_store_returns_empty_collections
    assert_empty @store.get_checkouts
    assert_empty @store.get_holds
  end

  def test_save_and_read_checkouts_roundtrip
    @store.save_checkouts([checkout(item_id: "1", title: "Dune")])

    result = @store.get_checkouts
    assert_equal 1, result.length
    assert_equal "Dune", result.first["title"]
  end

  def test_save_and_read_holds_roundtrip
    @store.save_holds([hold(item_id: "h1", title: "Neuromancer")])

    result = @store.get_holds
    assert_equal "Neuromancer", result.first["title"]
  end

  def test_checkouts_sorted_by_due_date
    @store.save_checkouts([
      checkout(item_id: "late", due_date: (Date.today + 20).to_s),
      checkout(item_id: "soon", due_date: (Date.today + 1).to_s),
      checkout(item_id: "mid", due_date: (Date.today + 10).to_s)
    ])

    ids = @store.get_all_data[:checkouts].map { |i| i["item_id"] }
    assert_equal %w[soon mid late], ids
  end

  def test_checkouts_with_unparseable_due_date_sort_last
    @store.save_checkouts([
      checkout(item_id: "bad", due_date: "not a date"),
      checkout(item_id: "good", due_date: (Date.today + 5).to_s)
    ])

    ids = @store.get_all_data[:checkouts].map { |i| i["item_id"] }
    assert_equal %w[good bad], ids
  end

  # Ties are the common case, not an edge case: due dates are dates rather
  # than timestamps, so a batch borrowed together shares one. sort_by is not
  # stable and the array is rebuilt each scrape, so without a tiebreaker these
  # rows could swap places between scrapes with nothing having changed.
  def test_checkouts_with_the_same_due_date_are_ordered_by_title
    same_day = (Date.today + 7).to_s
    @store.save_checkouts([
      checkout(item_id: "c", title: "Cherry", due_date: same_day),
      checkout(item_id: "a", title: "Apple", due_date: same_day),
      checkout(item_id: "b", title: "Banana", due_date: same_day)
    ])

    ids = @store.get_all_data[:checkouts].map { |i| i["item_id"] }
    assert_equal %w[a b c], ids
  end

  def test_checkout_order_is_stable_however_the_input_is_arranged
    same_day = (Date.today + 7).to_s
    items = 12.times.map do |i|
      checkout(item_id: "id#{i}", title: "Title #{i}", due_date: same_day)
    end

    orders = 6.times.map do |seed|
      @store.save_checkouts(items.shuffle(random: Random.new(seed)))
      @store.get_all_data[:checkouts].map { |i| i["item_id"] }
    end

    assert_equal 1, orders.uniq.length, "checkout order varied with input order"
  end

  def test_checkouts_sharing_a_title_are_ordered_by_item_id
    same_day = (Date.today + 7).to_s
    @store.save_checkouts([
      checkout(item_id: "copy2", title: "Dune", due_date: same_day),
      checkout(item_id: "copy1", title: "Dune", due_date: same_day)
    ])

    ids = @store.get_all_data[:checkouts].map { |i| i["item_id"] }
    assert_equal %w[copy1 copy2], ids
  end

  def test_holds_sharing_a_queue_position_are_ordered_by_title
    @store.save_holds([
      hold(item_id: "z", title: "Zebra", status: "not ready", queue_position: 4),
      hold(item_id: "m", title: "Mango", status: "not ready", queue_position: 4),
      hold(item_id: "a", title: "Apricot", status: "not ready", queue_position: 4)
    ])

    ids = @store.get_all_data[:holds].map { |i| i["item_id"] }
    assert_equal %w[a m z], ids
  end

  def test_ready_holds_sharing_a_deadline_are_ordered_by_title
    deadline = (Date.today + 3).to_s
    @store.save_holds([
      hold(item_id: "s", title: "Second", status: "ready", checkout_by: deadline),
      hold(item_id: "f", title: "First", status: "ready", checkout_by: deadline)
    ])

    ids = @store.get_all_data[:holds].map { |i| i["item_id"] }
    assert_equal %w[f s], ids
  end

  def test_holds_ordered_ready_then_waiting_then_paused
    @store.save_holds([
      hold(item_id: "paused", status: "paused", queue_position: 1),
      hold(item_id: "waiting", status: "not ready", queue_position: 2),
      hold(item_id: "ready", status: "ready", checkout_by: (Date.today + 3).to_s)
    ])

    ids = @store.get_all_data[:holds].map { |i| i["item_id"] }
    assert_equal %w[ready waiting paused], ids
  end

  def test_waiting_holds_sorted_by_queue_position
    @store.save_holds([
      hold(item_id: "third", status: "not ready", queue_position: 3),
      hold(item_id: "first", status: "not ready", queue_position: 1),
      hold(item_id: "no_position", status: "not ready")
    ])

    ids = @store.get_all_data[:holds].map { |i| i["item_id"] }
    assert_equal %w[first third no_position], ids
  end

  def test_not_ready_status_is_not_treated_as_ready
    # "not ready" contains the word "ready"; it must not be classified as ready.
    @store.save_holds([
      hold(item_id: "waiting", status: "not ready", queue_position: 5),
      hold(item_id: "ready", status: "ready")
    ])

    ids = @store.get_all_data[:holds].map { |i| i["item_id"] }
    assert_equal "ready", ids.first
  end

  def test_get_patron_data_filters_by_patron
    @store.save_checkouts([
      checkout(item_id: "1", patron_name: "Josh"),
      checkout(item_id: "2", patron_name: "Jett")
    ])
    @store.save_holds([hold(item_id: "h1", patron_name: "Jett")])

    data = @store.get_patron_data("Jett")
    assert_equal ["2"], data[:checkouts].map { |i| i["item_id"] }
    assert_equal ["h1"], data[:holds].map { |i| i["item_id"] }
    assert_equal "Jett", data[:patron_name]
  end

  def test_stats_count_totals_and_patrons
    @store.save_checkouts([
      checkout(item_id: "1", patron_name: "Josh"),
      checkout(item_id: "2", patron_name: "Jett")
    ])
    @store.save_holds([hold(item_id: "h1", patron_name: "Josh")])

    stats = @store.get_all_data[:stats]
    assert_equal 2, stats[:total_checkouts]
    assert_equal 1, stats[:total_holds]
    assert_equal %w[Jett Josh], stats[:patrons]
  end

  def test_stats_split_digital_and_physical
    @store.save_checkouts([
      checkout(item_id: "1", type: "eBook"),
      checkout(item_id: "2", type: "eAudiobook"),
      checkout(item_id: "3", type: "Book")
    ])

    stats = @store.get_all_data[:stats]
    assert_equal 2, stats[:digital_checkouts]
    assert_equal 1, stats[:physical_checkouts]
  end

  def test_stats_count_holds_ready_for_pickup
    @store.save_holds([
      hold(item_id: "r1", status: "ready"),
      hold(item_id: "r2", status: "available"),
      hold(item_id: "w1", status: "not ready"),
      hold(item_id: "p1", status: "paused")
    ])

    stats = @store.get_all_data[:stats]
    assert_equal 2, stats[:holds_ready]
    assert_equal 4, stats[:total_holds]
  end

  # "not ready" contains "ready"; a substring match would count it.
  def test_not_ready_holds_are_not_counted_as_ready
    @store.save_holds([hold(item_id: "w1", status: "not ready")])

    assert_equal 0, @store.get_all_data[:stats][:holds_ready]
  end

  # The count and the table's ready section come from the same predicate, so
  # they must agree.
  def test_holds_ready_count_matches_the_sorted_ready_section
    @store.save_holds([
      hold(item_id: "w1", status: "not ready", queue_position: 1),
      hold(item_id: "r1", status: "ready"),
      hold(item_id: "r2", status: "available")
    ])

    data = @store.get_all_data
    ready_in_table = data[:holds].take(data[:stats][:holds_ready]).map { |h| h["item_id"] }
    assert_equal %w[r1 r2], ready_in_table.sort
  end

  def test_stats_count_overdue_items
    @store.save_checkouts([
      checkout(item_id: "overdue", due_date: (Date.today - 2).to_s),
      checkout(item_id: "fine", due_date: (Date.today + 30).to_s)
    ])

    assert_equal 1, @store.get_all_data[:stats][:items_overdue]
  end

  def test_stats_ignore_unparseable_due_dates
    @store.save_checkouts([checkout(item_id: "bad", due_date: "whenever")])

    stats = @store.get_all_data[:stats]
    assert_equal 0, stats[:items_overdue]
    assert_equal 0, stats[:items_due_soon]
  end

  # Overdue and due-soon are distinct states: an item that is already overdue
  # must not also be counted as due soon.
  def test_overdue_items_are_not_counted_as_due_soon
    @store.save_checkouts([checkout(item_id: "overdue", due_date: (Date.today - 5).to_s)])

    stats = @store.get_all_data[:stats]
    assert_equal 1, stats[:items_overdue]
    assert_equal 0, stats[:items_due_soon]
  end

  def test_item_due_today_counts_as_due_soon_not_overdue
    # The boundary case: due today is not yet overdue.
    @store.save_checkouts([checkout(item_id: "today", due_date: Date.today.to_s)])

    stats = @store.get_all_data[:stats]
    assert_equal 0, stats[:items_overdue]
    assert_equal 1, stats[:items_due_soon]
  end

  def test_overdue_and_due_soon_counts_are_independent
    @store.save_checkouts([
      checkout(item_id: "overdue", due_date: (Date.today - 3).to_s),
      checkout(item_id: "soon", due_date: (Date.today + 2).to_s),
      checkout(item_id: "later", due_date: (Date.today + 30).to_s)
    ])

    stats = @store.get_all_data[:stats]
    assert_equal 1, stats[:items_overdue]
    assert_equal 1, stats[:items_due_soon]
    assert_equal 3, stats[:total_checkouts]
  end

  def test_due_soon_respects_due_soon_days_env
    original = ENV["DUE_SOON_DAYS"]
    ENV["DUE_SOON_DAYS"] = "2"

    @store.save_checkouts([
      checkout(item_id: "within", due_date: (Date.today + 1).to_s),
      checkout(item_id: "outside", due_date: (Date.today + 10).to_s)
    ])

    stats = @store.get_all_data[:stats]
    assert_equal 1, stats[:items_due_soon]
    assert_equal 2, stats[:due_soon_days]
  ensure
    ENV["DUE_SOON_DAYS"] = original
  end

  def test_log_scrape_attempt_records_success_and_failure
    @store.log_scrape_attempt("Josh", true, {checkouts: 3, holds: 1})
    @store.log_scrape_attempt("Jett", false, {}, "login failed")

    failures = @store.get_recent_scrape_failures
    assert_equal 1, failures.length
    assert_equal "login failed", failures.first["error_message"]
  end

  # A patron's own page shows only their failures: another patron's login
  # trouble says nothing about whether this page's data is current.
  def test_scrape_failures_can_be_filtered_by_patron
    @store.log_scrape_attempt("Josh", false, {}, "josh broke")
    @store.log_scrape_attempt("Jett", false, {}, "jett broke")
    @store.log_scrape_attempt("Josh", false, {}, "josh broke again")

    assert_equal 3, @store.get_recent_scrape_failures.length
    assert_equal ["josh broke again", "josh broke"],
      @store.get_recent_scrape_failures("Josh").map { |f| f["error_message"] }
    assert_equal ["jett broke"],
      @store.get_recent_scrape_failures("Jett").map { |f| f["error_message"] }
  end

  def test_scrape_failures_for_a_patron_with_none_is_empty
    @store.log_scrape_attempt("Josh", false, {}, "josh broke")

    assert_empty @store.get_recent_scrape_failures("Autumn")
  end

  def test_successful_scrapes_are_never_reported_as_failures
    @store.log_scrape_attempt("Josh", true, {checkouts: 5})

    assert_empty @store.get_recent_scrape_failures("Josh")
  end

  def test_get_last_scrape_time_reflects_latest_successful_scrape
    assert_nil @store.get_last_scrape_time

    @store.log_scrape_attempt("Josh", true, {checkouts: 1})
    refute_nil @store.get_last_scrape_time
  end

  def test_thumbnail_save_and_exists
    refute @store.thumbnail_exists?("abc")

    @store.save_thumbnail("abc", "fake-image-bytes")

    assert @store.thumbnail_exists?("abc")
    assert_equal "fake-image-bytes", File.read(@store.get_thumbnail_path("abc"))
  end
end
