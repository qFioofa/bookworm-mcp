# Analytical search scenarios

Bookworm stays retrieval-only. A scenario is a declarative recipe: it names the
goal, the tool order, the stop condition, and the evidence rules. The bot reads
a recipe and runs the tools; it does not get a ready answer from the server.

## Scenario vector

| Id | Scenario | Tool combination | Stop condition |
|---|---|---|---|
| `triage` | Corpus triage | `list_documents` → `stats` → `get_document` → `get_outline` | documents and outline are known |
| `fact_lookup` | Fact or thesis lookup | `search` → `read_passage` → `find_quote` | 2–3 passages read with citations |
| `quote_verification` | Quote verification | `find_quote` → `read_passage` | every occurrence is verified or missing |
| `chapter_study` | Chapter study | `get_outline` → `read_chapter` → `search(filters.node_id)` | chapter range is read |
| `entity_profile` | Entity profile | `search_entities` → `get_entity` → `get_relations` → `read_passage` | mentions and relations are read |
| `concept_chain` | Concept chain | `search_entities` ×2 → `get_logical_chain` → `get_relations` → `read_passage` | chain found or absence reported |
| `case_collection` | Case collection | `find_cases` → `get_case` → `read_passage` | cases opened and cited |
| `cross_book_comparison` | Cross-book comparison | `list_documents` → per-document `search`/`search_entities`/`get_relations`/`find_quote` | each document has own citations |
| `evidence_pack` | Evidence pack | `search` ×2 → `read_chapter` → `find_cases` → `get_relations` | queries paged, chapters and cases opened |
| `notes_cross_check` | Notes cross-check | `ingest_text` → `find_quote` → `search` → `read_passage` | each claim marked book/text/missing |

The source of truth is `lib/bookworm/scenarios/definitions.yml`. Titles,
descriptions, stop conditions, and guardrails live in
`lib/bookworm/locales/{en,ru}.yml` under `scenarios.*`.

## Bot entry point

The server exposes the recipes as MCP prompts. The bot connects to the same
transport as for tools: stdio (`bundle exec bookworm-mcp`) or HTTP
(`http://host:9292/mcp`).

```text
bin/bookworm-mcp
  → Bookworm::MCP::CLI.start            lib/bookworm/mcp/cli.rb
  → Bookworm::App.new                   lib/bookworm/app.rb
  → Bookworm::MCP.build_server(app)     lib/bookworm/mcp/server.rb
  → tools: Tools::ALL, prompts: Prompts::ALL
```

MCP call sequence:

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

The response is one `user` message with the recipe. The bot then calls tools
from the recipe and writes the answer from the returned citations:

```text
1. search        { "query": "loss aversion", "document_id": "doc_...", "k": 5 }
2. read_passage  { "passage_id": "doc_...:p12", "before": 1, "after": 1 }
3. find_quote    { "quote": "people dislike losses more than gains",
                   "document_id": "doc_...", "source": "book" }
```

If the MCP client does not surface prompts, read the recipe from
`prompts/get` with any MCP client, or use this document and
`definitions.yml` directly. A read-only `list_scenarios`/`get_scenario` tool
pair is a possible fallback, but is not needed for clients that support prompts.

For an in-process Ruby bot, skip MCP and call `Bookworm::App` methods directly:
`app.search(...)`, `app.read_passage(...)`, and so on.

## Guardrails

Every prompt carries a subset of the shared rules from
`locales.*.scenarios.guardrails`:

- `citations_required` — every claim carries `passage_id` and `citation`.
- `no_invented_quotes` — no quote that a tool did not return.
- `verified_only` — `verified=false`, fuzzy matches, and `no_evidence` are gaps.
- `text_warning` — text-fragment evidence is not book evidence.
- `graph_descriptive` — graph links are rule-based, not truth.
- `no_evaluation` — the server does not rate quality or truth.
- `no_answer` — the server retrieves; the bot writes.
- `report_gaps` — empty results are reported, not filled.
- `separate_citations` — never merge passages from different books.
- `pagination` — follow `next_offset`, `next_cursor`, and `limit`.

## Add a scenario

1. Append an entry to `lib/bookworm/scenarios/definitions.yml` with `id`,
   `steps`, optional `requires`, `stop_when`, `output`, and `guardrails`.
2. Add `scenarios.<id>.{title,description,when,stop_when,output}` to both locale
   files.
3. Run `bundle exec rake test`. `test/scenarios_test.rb` checks unique ids and
   that every step references a registered tool.

A step may use `requires: document_id`. The renderer then skips that step when
the prompt argument is empty, so a triage prompt still works for a whole corpus.

Step arguments are templates. `{{document_id}}`, `{{request}}`, and
`{{language}}` are interpolated from prompt arguments. A placeholder that is the
whole value is dropped when the argument is blank; an embedded placeholder is
replaced with an empty string.
