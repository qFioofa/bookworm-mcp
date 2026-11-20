FROM ruby:3.3-slim

ENV LANG=C.UTF-8 \
    BUNDLE_WITHOUT=development \
    BOOKWORM_LOCALE=en

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      pkg-config \
      libssl-dev \
      poppler-utils \
      tesseract-ocr \
      tesseract-ocr-rus \
      djvulibre-bin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock bookworm-mcp.gemspec ./
COPY lib ./lib
COPY bin ./bin
COPY README.md LICENSE ./

RUN bundle install

EXPOSE 9292 9443

ENTRYPOINT ["bundle", "exec", "bookworm-mcp"]
