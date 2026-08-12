require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "json"
require "time"

# Tests must never touch the real data/ directory or the live .env, so the
# libraries are loaded directly rather than through app.rb.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

# Skip the scraper's politeness delay between pages; tests drive fake pages.
ENV["PAGE_SETTLE_SECONDS"] ||= "0"

# Safety net: the repo's .env holds live library credentials, and dotenv loads
# it into any process that requires app.rb. A test that accidentally reaches
# the real scraper would then log in to the library for real. Clearing the
# credentials here means such a test fails loudly instead.
ENV.keys.grep(/^PATRON_/).each { |k| ENV.delete(k) }
ENV["LIBRARY_URL"] = "https://library.invalid"

require "data_store"
require "item_tracker"

module TempDataDir
  # Gives each test an isolated data directory that is removed afterwards.
  def setup
    super
    @tmp_dir = Dir.mktmpdir("dewey-test")
  end

  def teardown
    @tracker&.close
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.exist?(@tmp_dir)
    super
  end

  # Builds a checkout hash shaped like the scraper's output. String keys
  # throughout, matching what the scraper actually produces.
  def checkout(item_id:, patron_name: "Josh", title: "A Book", due_date: nil, type: nil, **rest)
    {
      "item_id" => item_id,
      "patron_name" => patron_name,
      "title" => title,
      "due_date" => due_date || (Date.today + 14).to_s,
      "type" => type
    }.merge(rest.transform_keys(&:to_s))
  end

  def hold(item_id:, patron_name: "Josh", title: "A Held Book", status: "not ready", **rest)
    {
      "item_id" => item_id,
      "patron_name" => patron_name,
      "title" => title,
      "status" => status
    }.merge(rest.transform_keys(&:to_s))
  end
end
