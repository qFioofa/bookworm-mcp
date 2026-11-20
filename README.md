# bookworm-mcp

Local-first MCP server for analytical book search.

It searches books and text fragments and returns ranked passages with citations,
offsets, and score breakdowns. It also builds a rule-based entity graph and
finds examples/cases. It does **not** evaluate a book, rank ideas by quality, or
write an answer.

Current version is **in-memory only**: documents are lost when the server exits.
There is no database, no vector index, and no API key requirement.

## Features

- Books: EPUB, PDF, FB2, DjVu, Markdown, TXT.
- Direct text: `ingest_text` for an article, a passage, or a fragment.
- Smart lexical search: exact terms, quoted phrases, `+required`, `-excluded`,
  stemming for Russian and English, typo tolerance through trigram fallback.
- Evidence-first results: passage id, book/chapter/page, character offsets,
  quote hash, and `verified` flag.
- Outline: chapters and sections with page and character ranges.
- Passage reading with neighbouring passages.
- Quote lookup and verification with `find_quote`.
- Entity graph: rule-based entities, mentions, typed relations, and evidence.
- Cases: examples, illustrations, anecdotes, and case studies found by marker,
  query, or anchor entity.
- PlantUML output for relations and logical chains.
- Interface locales: English and Russian.
- Ephemeral text documents with TTL.
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

### Docker Compose

`compose.yml` builds the image, starts the HTTP/HTTPS server, publishes both
ports on `127.0.0.1`, and defines a healthcheck.

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
```

## Tools

| Tool | Purpose |
|---|---|
| `ingest_book` | Parse a local book file into memory |
| `ingest_text` | Create an ephemeral document from inline text |
| `list_documents` | List books and text fragments |
| `get_document` | Metadata and a shallow outline |
| `get_outline` | Chapter/section tree |
| `read_passage` | Read a passage and its neighbours |
| `search` | Smart search over one document or all documents |
| `find_quote` | Find and verify a quote |
| `search_entities` | Find extracted entities and terms |
| `get_entity` | Entity profile with mentions, relations, and cases |
| `get_relations` | Rule-based entity graph, JSON or PlantUML |
| `get_logical_chain` | Shortest evidence-backed chain between two entities |
| `find_cases` | Find examples and cases by marker, query, or anchor |
| `get_case` | Read one case with evidence and linked entities |
| `delete_document` | Remove a document from memory |
| `stats` | In-memory counts and configuration |

## Search

`search` accepts:

- `query` — plain terms, `"a quoted phrase"`, `+required`, `-excluded`.
- `document_id` — scope to one document.
- `text` — index inline text for this call instead of `document_id`.
- `mode` — `smart` (default), `lexical`, `exact`, `fuzzy`.
- `k`, `cursor` — pagination.
- `include_text`, `max_tokens` — return full passage text under a budget.
- `filters` — `kind`, `language`, `node_id`, `page_min`, `page_max`.

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
- `INFLUENCES`
- `EXAMPLE_OF`
- `PRECEDES`
- `CO_OCCURS`

Every relation carries evidence: citation, quote, character range, method, and
confidence. Confidence means extraction certainty, not truth.

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
`например`, `к примеру`, `кейс`, or by an example/case heading. This is
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

Verify a quote:

```json
{
  "name": "find_quote",
  "arguments": {
    "document_id": "doc_...",
    "quote": "people dislike losses more than gains"
  }
}
```

## Architecture

```text
MCP client
  │ stdio or Streamable HTTP
  ▼
Bookworm::MCP
  tools / schemas / responder / i18n
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

- In-memory only: restart loses all documents.
- No embeddings or vector search yet. `vector` in the score breakdown is always
  `0.0`.
- PDF extraction is text-layer based. Scanned PDFs require OCR and return
  `OCR_REQUIRED`.
- DjVu requires the external `djvutxt` binary (`djvulibre-bin`).
- Graph extraction is rule-based. It is useful for navigation and evidence
  gathering, not for full semantic parsing.
- Cases are marker-based candidates; they do not yet have problem/solution/
  outcome fields.
- Search is lexical; semantic search is a later layer.

## Development

```bash
make test
# or
bundle exec rake test
```

## License

MIT
