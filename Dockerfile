# Two stages, so the compilers used to build native gems do not ship to
# production. build-essential and git are ~400MB and are only ever needed by
# `bundle install`; the runtime stage takes the built gems and leaves the
# toolchain behind.
FROM ruby:4.0.6-slim AS gems

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./

RUN bundle lock --add-platform x86_64-linux \
    && bundle config set --local deployment true \
    && bundle config set --local without "development test" \
    && bundle install


FROM ruby:4.0.6-slim

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# curl is needed by the healthcheck; the rest are Chromium's runtime libraries.
RUN apt-get update && apt-get install -y \
    curl \
    fonts-unifont \
    libasound2t64 \
    libatk-bridge2.0-0t64 \
    libatk1.0-0t64 \
    libcairo2 \
    libcups2t64 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libglib2.0-0t64 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libx11-6 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash app

WORKDIR /app

# Must match Playwright::COMPATIBLE_PLAYWRIGHT_VERSION from the playwright-ruby-client gem
RUN npm init -y \
    && npm install playwright@1.60.0 \
    && npx playwright install chromium

# The built gems, plus the bundle config that points Ruby at them. The config
# is not in /app/.bundle: the ruby base image sets BUNDLE_APP_CONFIG, so
# `bundle config --local` writes to /usr/local/bundle/config instead.
# Both come from the build stage already owned by app, so nothing needs a
# chown -R afterwards -- that rewrites every file into a new 44MB layer.
COPY --from=gems --chown=app:app /app/vendor /app/vendor
COPY --from=gems --chown=app:app /usr/local/bundle/config /usr/local/bundle/config

RUN mkdir -p /app/data /app/data/thumbnails \
    && chown -R app:app /app/data \
    && chmod 777 /app/data /app/data/thumbnails

COPY --chown=app:app . .

USER app

EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:4567/health || exit 1

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
