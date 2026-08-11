FROM ruby:3.4.8-slim

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    gnupg \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs

WORKDIR /app

COPY Gemfile Gemfile.lock ./

RUN bundle lock --add-platform x86_64-linux \
    && bundle config set --local deployment true \
    && bundle config set --local without "development test" \
    && bundle install

RUN apt-get update && apt-get install -y \
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

RUN npm init -y \
    && npm install playwright@1.57.0 \
    && npx playwright install chromium

RUN mkdir -p /app/data /app/data/thumbnails \
    && chmod 777 /app/data /app/data/thumbnails

COPY . .

RUN useradd --create-home --shell /bin/bash app \
    && chown -R app:app /app

USER app

EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:4567/health || exit 1

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
