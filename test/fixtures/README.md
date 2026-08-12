# Test fixtures

Saved BiblioCommons markup used by `test/test_scraper_extraction.rb` to exercise
the scraper's CSS selectors without hitting the live site.

These are **scrubbed** captures of real pages. Only the item markup the scraper
parses was kept; the `<head>`, every `<script>` block, and the inline JSON app
config were discarded, because that is where the session ID, auth token, library
card barcode and account email appear. Titles and authors were replaced with
public-domain works so the fixtures do not record real borrowing history.

## Regenerating

The scraper can dump the pages it visits:

```bash
DUMP_HTML_DIR=/tmp/dewey-dumps bundle exec ruby -Ilib -e '...scrape...'
```

**Raw dumps contain live credentials and must never be committed.** Dump to a
directory outside the repository, strip everything except the
`.batch-actions-list-item-details` blocks, replace titles/authors, and re-check
for `sessionId`, `authToken`, `encodedUserId`, `barcode`, and any email address
before adding the result here.
