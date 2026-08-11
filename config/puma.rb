# Single worker by design. The Rufus scheduler that drives scraping starts in
# DeweyApp#initialize, so every additional worker boots its own scheduler and
# fires a duplicate, concurrent scrape. Dewey serves one household's dashboard,
# so one worker is ample; do not raise this without moving the scheduler out of
# the web process.
workers ENV.fetch("WEB_CONCURRENCY") { 0 }
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count

preload_app!

# rackup DefaultRackup
port ENV.fetch("PORT") { 4567 }
environment ENV.fetch("RACK_ENV") { "development" }

on_worker_boot do
  # Worker specific setup for Rails 4.1+
  # See: https://devcenter.heroku.com/articles/deploying-rails-applications-with-the-puma-web-server#on-worker-boot
end

# Allow puma to be restarted by `rails restart` command.
plugin :tmp_restart
