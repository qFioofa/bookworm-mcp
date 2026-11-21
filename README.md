# bookworm-mcp

Local-first MCP server for analytical book search.

It searches books and text fragments and returns ranked passages with citations,
offsets, and score breakdowns. It also builds a rule-based entity graph and
finds examples/cases. It does **not** evaluate a book, rank ideas by quality, or
write an answer.

Current version is **in-memory only**: documents are lost when the server exits.
There is no database, no vector index, and no API key requirement.

## Features

- Books: EPUB, PDF, FB2 (including ZIP-wrapped `.fb2` and `.fb2.zip`),
  DjVu, Markdown, TXT.
- FB2 structure: chapters, nested sections, tables, epigraphs, and inline
  footnotes with their text preserved separately from the main body.
- Direct text: `ingest_text` for an article, a passage, or a fragment, from
  inline text, a local `source_path`, or an HTTP(S) `source_url`.
- Batch file ingestion: `ingest_books` for several local paths in one call.
- Document updates: `replace: true` removes the previous version of the same path
  before adding the new one.
- Unicode-safe paths: NFC and decomposed filenames resolve to the same file.
- TOC filtering: EPUB `nav` documents and link-only contents pages, plus
  Markdown anchor lists, are kept out of the passage corpus.
- Lexical search: exact terms, quoted phrases, `+required`, `-excluded`,
  stemming for Russian and English, typo tolerance through trigram fallback.
  A phrase query that finds nothing is retried with relaxed phrase terms.
  There are no embeddings; `semantic` is always `false` and `retrieval` is
  `lexical`.
- Evidence-first results: passage id, book/chapter/page, character offsets,
  quote hash, and `verified` flag. `verbosity=compact` and
  `include_breakdown=false` keep search responses small.
- Outline: chapters and sections with page, character, and content ranges.
  `get_outline` supports `max_nodes` and `titles_only`; `get_document` returns
  only a shallow title outline.
- Passage reading with neighbouring passages, plus `read_chapter` for a whole
  chapter or section with pagination and linked footnotes.
- Quote lookup and verification with `find_quote`, including full-text spans,
  book-first ordering, source labels, and footnote quotes.
- Entity graph: rule-based entities, mentions, typed relations, and evidence.
  Russian name forms such as `Павел`, `Павла`, and `Павлу` are merged into one
  entity with aliases. Weak `CO_OCCURS` links are hidden below the default
  `min_confidence` of `0.5`.
- Cases: examples, illustrations, anecdotes, and case studies found by marker,
  query, or anchor entity. Adjacent passages of one case are merged into a
  single case with `passage_ids` and a content range.
- Analytical scenarios as MCP prompts: `triage`, `fact_lookup`,
  `quote_verification`, `chapter_study`, `entity_profile`, `concept_chain`,
  `case_collection`, `cross_book_comparison`, `evidence_pack`, and
  `notes_cross_check`. Each prompt returns a tool recipe with guardrails. See
  `docs/scenarios.md`.
- PlantUML output for relations and logical chains.
- Interface locales: English and Russian.
- Ephemeral text documents with TTL.
- Stable document ids and in-process ingest deduplication by `source_hash`.
  Re-ingesting the same book file or the same inline text returns the existing
  document and reports `cached: true`.
- No evaluation fields: no rating, quality, sentiment, recommendation, or truth
  score.

## Install

```bash
make install
make test
bundle exec bookworm-mcp --version
```

Without Make:

```bash
bundle install
bundle exec rake test
```

## Run as an MCP server

```bash
make run
# or
bundle exec bookworm-mcp
```

By default, the server speaks MCP over stdio.

Example for an MCP client:

```json
{
  "mcpServers": {
    "bookworm": {
      "command": "bundle",
      "args": ["exec", "bookworm-mcp"],
      "cwd": "/home/qFioofa/bookworm-mcp"
    }
  }
}
```

Or with Claude Code:

```bash
claude mcp add bookworm -- bundle exec bookworm-mcp
```

## Run as an HTTP/HTTPS server

Start the same server with the Streamable HTTP transport (Rack + Puma):

```bash
make serve
# or
bundle exec bookworm-mcp --http --host 127.0.0.1 --port 9292 --https-port 9443
```

By default the server listens on both protocols:

- `http://localhost:9292/mcp`
- `https://localhost:9443/mcp`

`GET /health` returns JSON status on either listener.

When no certificate is configured, the HTTPS listener generates a self-signed
certificate for `localhost`, `127.0.0.1`, and `::1`. To use your own PEM files:

```bash
bundle exec bookworm-mcp --http \
  --ssl-cert /path/to/cert.pem \
  --ssl-key /path/to/key.pem
```

Disable the TLS listener with `--no-https`.

Point an MCP client at one of the URLs:

```json
{
  "mcpServers": {
    "bookworm": {
      "type": "http",
      "url": "https://localhost:9443/mcp"
    }
  }
}
```

Use `http://localhost:9292/mcp` when the client does not accept the self-signed
certificate. Clients must trust the certificate used by the HTTPS listener.

The HTTP transport is stateless: every POST is self-contained, sessions and
database are not used. Responses are JSON, so clients send
`Accept: application/json, text/event-stream`. All clients share the same
in-memory documents, and the documents are lost when the process exits.

| Flag | Env | Default | Purpose |
|---|---|---|---|
| `--http` | — | off | Run HTTP/HTTPS instead of stdio |
| `--[no-]https` | `BOOKWORM_HTTPS` | on | Add the TLS listener |
| `--host HOST` | `BOOKWORM_HTTP_HOST` | `127.0.0.1` | Bind host |
| `--port PORT` | `BOOKWORM_HTTP_PORT` | `9292` | HTTP port |
| `--https-port PORT` | `BOOKWORM_HTTPS_PORT` | `9443` | HTTPS port |
| `--path PATH` | `BOOKWORM_HTTP_PATH` | `/mcp` | MCP endpoint path |
| `--allowed-hosts HOSTS` | `BOOKWORM_HTTP_ALLOWED_HOSTS` | empty | Extra allowed `Host` values |
| `--ssl-cert PATH` | `BOOKWORM_SSL_CERT` | generated | TLS certificate (PEM) |
| `--ssl-key PATH` | `BOOKWORM_SSL_KEY` | generated | TLS private key (PEM) |

Bind to `0.0.0.0` only when the server must be reachable from outside the
machine.

## Docker

```bash
make docker-build
make docker-run
```

The image is `bookworm-mcp` and runs the stdio server by default. For an
interactive MCP client use `docker run --rm -i bookworm-mcp`.

To expose both HTTP and HTTPS ports:

```bash
make docker-run-http
# or
docker run --rm -p 9292:9292 -p 9443:9443 bookworm-mcp --http --host 0.0.0.0
```

Mount host books so `ingest_book` can read them inside the container:

```bash
docker run --rm -p 9292:9292 -v "$PWD/books:/books:ro" bookworm-mcp --http --host 0.0.0.0
```

Then pass the container path, for example `{"path": "/books/book.epub"}`.

### Docker Compose

`compose.yml` builds the image, starts the HTTP/HTTPS server, publishes both
ports on `127.0.0.1`, mounts `./books` at `/books` read-only, and defines a
healthcheck. Override the host directory with `BOOKWORM_BOOKS_DIR`.

```bash
make compose-up     # build, start, wait for healthy
make compose-ps     # status
make compose-logs   # follow logs
make compose-down   # stop and remove
```

Endpoints: `http://localhost:9292/mcp` and `https://localhost:9443/mcp`.

Override the published ports or locale through the environment:

```bash
BOOKWORM_HTTP_PORT=9000 BOOKWORM_HTTPS_PORT=9443 BOOKWORM_LOCALE=ru make compose-up
BOOKWORM_BOOKS_DIR=/srv/books make compose-up
```

## Tools

| Tool | Purpose |
|---|---|
| `ingest_book` | Parse a local book file into memory |
| `ingest_books` | Parse several local book files in one call |
| `ingest_text` | Create an ephemeral document from inline text, `source_path`, or `source_url` |
| `list_documents` | List books and text fragments |
| `get_document` | Metadata and a shallow outline |
| `get_outline` | Chapter/section tree with caps (`max_nodes`, `titles_only`) |
| `read_passage` | Read a passage, its neighbours, and linked footnotes |
| `read_chapter` | Read a whole chapter/section with pagination and footnotes |
| `search` | Smart search over one document or all documents |
| `find_quote` | Find and verify a quote; prefer books over text fragments |
| `search_entities` | Find extracted entities and terms |
| `get_entity` | Entity profile with mentions, relations, and cases |
| `get_relations` | Rule-based entity graph, JSON or PlantUML |
| `get_logical_chain` | Shortest evidence-backed chain between two entities |
| `find_cases` | Find examples and cases by marker, query, or anchor |
| `get_case` | Read one case with evidence and linked entities |
| `delete_document` | Remove a document from memory |
| `stats` | In-memory counts, cache stats, and optional per-document stats |

## Scenarios

The server also exposes ten retrieval recipes as MCP prompts. A prompt is a
tool order with a stop condition and evidence rules; it is not an answer.

```json
{ "jsonrpc": "2.0", "id": 1, "method": "prompts/list" }
```

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "prompts/get",
  "params": {
    "name": "scenario_fact_lookup",
    "arguments": {
      "request": "what does the book say about loss aversion",
      "document_id": "doc_..."
    }
  }
}
```

The response is a `user` message with the steps, their arguments, the stop
condition, and guardrails. The bot calls the tools itself and cites the
returned passages. Scenario definitions live in
`lib/bookworm/scenarios/definitions.yml`; titles and guardrails live in the
locale files under `scenarios.*`. See `docs/scenarios.md` for the full vector.

## Search

`search` accepts:

- `query` — plain terms, `"a quoted phrase"`, `+required`, `-excluded`.
- `document_id` — scope to one document.
- `text` — index inline text for this call instead of `document_id`.
- `mode` — `smart` (default), `lexical`, `exact`, `fuzzy`.
- `k`, `cursor` — pagination.
- `include_text`, `max_tokens` — return full passage text under a budget.
- `verbosity` — `full` (default) or `compact`.
- `include_breakdown` — set `false` to omit `score_breakdown`.
- `filters` — `kind`, `language`, `node_id`, `page_min`, `page_max`.

If a phrase query returns nothing in `smart` mode, the server retries with the
phrase terms relaxed and sets `fallback: "relaxed_phrase"`.

Every hit includes:

```json
{
  "rank": 1,
  "passage_id": "txt_...:p1",
  "citation": {
    "document_id": "txt_...",
    "document_kind": "text",
    "document_title": "Loss aversion",
    "passage_id": "txt_...:p1",
    "node_id": "txt_...:n0",
    "chapter_path": [],
    "page": null,
    "paragraph_index": 0,
    "start_char": 0,
    "end_char": 83,
    "quote_hash": "5a74...",
    "verified": true
  },
  "snippet": "Loss aversion is a cognitive bias.",
  "highlights": [{ "start": 0, "end": 4, "term": "loss" }],
  "score": 1.0,
  "score_breakdown": {
    "lexical": 0.63,
    "vector": 0.0,
    "phrase": 0.0,
    "title": 0.8,
    "exact": 0.0,
    "fuzzy": 0.0,
    "fused": 1.43
  },
  "matched_terms": ["loss", "aversion"],
  "coverage": 1.0,
  "match_type": "lexical"
}
```

`score` is retrieval relevance, not book quality. `verified` means the passage
span exists in the parsed text.

## Graph and cases

Entities are extracted with rules: quoted terms, acronyms, capitalized names,
and RAKE key phrases (`rake-text`). Relations are rule-based:

- `IS_A`
- `CAUSES`
- `CONTRASTS`
- `INCLUDES`
- `PART_OF`
- `INFLUENCES`
- `EXAMPLE_OF`
- `PRECEDES`
- `CO_OCCURS`

Every relation carries evidence: citation, quote, character range, method, and
confidence. Confidence means extraction certainty, not truth. `get_relations`
and `get_logical_chain` omit links below `min_confidence`; the default `0.5`
excludes weak `CO_OCCURS` links. Set `min_confidence: 0` to include them, or
filter explicitly with `predicates`.

Find an entity:

```json
{
  "name": "search_entities",
  "arguments": {
    "document_id": "doc_...",
    "query": "loss aversion"
  }
}
```

Get its graph as PlantUML:

```json
{
  "name": "get_relations",
  "arguments": {
    "entity_id": "ent_...",
    "depth": 1,
    "format": "plantuml",
    "max_nodes": 30
  }
}
```

Build a logical chain:

```json
{
  "name": "get_logical_chain",
  "arguments": {
    "document_id": "doc_...",
    "start": "Loss aversion",
    "finish": "risk seeking",
    "format": "plantuml"
  }
}
```

Find cases:

```json
{
  "name": "find_cases",
  "arguments": {
    "document_id": "doc_...",
    "query": "loss",
    "limit": 5
  }
}
```

Cases are found by markers such as `for example`, `such as`, `case study`,
`например`, `к примеру`, `кейс`, or by an example/case heading. Adjacent
passages that belong to one section or marker run are merged into one case.
The payload includes `passage_ids`, `chapter_path`, and a character range; use
`get_case` to receive every constituent passage with its own citation. This is
candidate discovery, not a semantic case schema.

PlantUML is returned as source text. `include_url: true` additionally returns a
`plantuml_url` encoded with `plantuml_builder`; the diagram is only rendered
when that URL is opened.

## i18n

The interface supports English and Russian. Locale files are split by language:

- `lib/bookworm/locales/en.yml`
- `lib/bookworm/locales/ru.yml`

They hold UI strings, tool titles and descriptions, schema descriptions, search
stopwords, stemmer suffixes, entity stopwords, RAKE stopwords, relation cues,
case markers, and heading patterns.

Use an environment variable:

```bash
BOOKWORM_LOCALE=ru bundle exec bookworm-mcp
```

Or a CLI flag:

```bash
bundle exec bookworm-mcp --locale ru
```

The flag is read before the app loads, so MCP tool titles and descriptions are
localized too. Search content is multilingual and is not translated.

## Examples

Ingest a book:

```json
{
  "name": "ingest_book",
  "arguments": {
    "path": "/home/user/Books/book.epub"
  }
}
```

Search inside it:

```json
{
  "name": "search",
  "arguments": {
    "document_id": "doc_...",
    "query": "\"loss aversion\" -gains",
    "k": 5,
    "include_text": true
  }
}
```

Search an inline fragment without a book:

```json
{
  "name": "search",
  "arguments": {
    "text": "Loss aversion is a cognitive bias. People dislike losses more than gains.",
    "title": "Fragment",
    "query": "loss aversion"
  }
}
```

Read a chapter from the outline:

```json
{
  "name": "read_chapter",
  "arguments": {
    "document_id": "doc_...",
    "node_id": "doc_...:n3",
    "limit": 50
  }
}
```

Ingest a large text without sending it inline:

```json
{
  "name": "ingest_text",
  "arguments": {
    "source_path": "/home/user/notes/article.md",
    "title": "Article"
  }
}
```

Batch ingest several books:

```json
{
  "name": "ingest_books",
  "arguments": {
    "paths": ["/home/user/Books/a.fb2", "/home/user/Books/b.epub"]
  }
}
```

Verify a quote against the book:

```json
{
  "name": "find_quote",
  "arguments": {
    "document_id": "doc_...",
    "quote": "people dislike losses more than gains",
    "source": "book"
  }
}
```

`source` is `any` (default), `book`, or `text`. With `any`, book occurrences
come first. Every occurrence has `verification.source` (`book`, `text`, or
`footnote`) and `book_evidence`/`text_evidence` totals are returned. Quotes
confirmed only against an `ingest_text` fragment carry a warning.

## Architecture

```text
MCP client
  │ stdio or Streamable HTTP
  ▼
Bookworm::MCP
  tools / prompts / schemas / responder / i18n
  ▼
Bookworm::Scenarios
  catalog / definitions / renderer
  ▼
Bookworm::App
  ingest, search, read, quote, graph, cases
  ├── Ingest::Pipeline
  │   ├── EPUB / PDF / FB2 / DjVu / Markdown / TXT adapters
  │   ├── DocumentBuilder
  │   └── Chunker
  ├── Store::MemoryStore
  ├── Search::Engine
  │   ├── Tokenizer + Stemmer
  │   ├── BM25 index
  │   └── Trigram fuzzy fallback
  └── Analysis
      ├── Extractor (entities, relations, RAKE terms)
      ├── CaseExtractor
      ├── Graph (RGL)
      └── Plantuml
```

The same `Document` model represents a book and a text fragment. For a text
fragment, `page` is `null`, `chapter_path` can be empty, and citations use
character offsets.

## Limitations

- In-memory only: restart loses all documents. Ingest deduplication is
  in-process; after a restart, ingest the book once more by `path`. Stable ids
  make the same file reproducible, but the raw text is never sent again.
- In Docker, `ingest_book` can only read paths that exist inside the container.
  Mount the host directory (`-v /host/books:/books:ro`) and pass `/books/...`.
- No embeddings or vector search yet. `vector` in the score breakdown is always
  `0.0`.
- PDF extraction is text-layer based. Scanned PDFs require OCR and return
  `OCR_REQUIRED`.
- DjVu requires the external `djvutxt` binary (`djvulibre-bin`).
- Graph extraction is rule-based. It is useful for navigation and evidence
  gathering, not for full semantic parsing.
- Cases are marker-based candidates; they do not yet have problem/solution/
  outcome fields.
- Footnote text is available through `read_passage`, `read_chapter`, and
  `find_quote`; the main `search` index still covers body passages only.
- `source_path` accepts text/Markdown files; use `ingest_book` for FB2/EPUB/PDF.
- `source_url` supports only HTTP(S), follows at most three redirects, must look
  like a text resource, and is limited by `max_inline_bytes`. Local files are
  preferred.
- `ingest_text` rejects empty and placeholder-like values such as
  `$(placeholder)` or `{{value}}`.
- Entity merging is heuristic, including Russian case forms. Aliases keep the
  original surface forms.
- Search is lexical; semantic search is a later layer.

## Development

```bash
make test
# or
bundle exec rake test
```

## License

MIT
