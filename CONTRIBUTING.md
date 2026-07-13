# Contributing to Crux Console

Crux Console is a web UI for querying [Crux](https://github.com/juxt/crux)
(bitemporal database). It consists of:

| Path                  | What it is                                                        |
|-----------------------|-------------------------------------------------------------------|
| `src/crux_ui/`        | Frontend SPA — ClojureScript, re-frame + reagent, built by shadow-cljs |
| `src/crux_ui_lib/`    | Async HTTP client for the Crux REST API (used by the frontend)    |
| `src/crux_ui_server/` | Backend — Clojure, aleph HTTP server that serves the SPA and can optionally embed a Crux node |
| `resources/static/`   | Static assets; compiled JS lands in `resources/static/crux-ui/compiled/` |
| `test/`               | ClojureScript tests (browser test runner)                         |

The browser talks to a Crux node **directly** over its HTTP API — the console
server only serves the frontend (and optionally starts the Crux node for you).

## Prerequisites

- **JDK** 8+ (the release build targets Java 8; Java 11/17 work for local dev)
- **Leiningen** ≥ 2.9.1
- **Node.js** and **Yarn** (`yarn install` fetches npm deps, including shadow-cljs)

## Running in development

You need two processes: the frontend compiler (hot reload) and the server.

### 1. Frontend — shadow-cljs watch

```sh
yarn install          # once
dev/shadow-dev.sh     # = node_modules/.bin/shadow-cljs watch dev
```

The `dev` build compiles without optimizations to the same output dir the
server serves from, hot-swaps code on save, and includes
[re-frame-10x](https://github.com/day8/re-frame-10x) for inspecting app state.

(`lein cljs-dev` also works but watches the `app` build, which compiles with
`:advanced` optimizations — much slower feedback; prefer the `dev` build.)

Note: shadow-cljs prints many
`failed to inspect resource ".../es5-ext/... #/..." ` warnings — these are
harmless (npm files with `#` in their paths) and can be ignored.

### 2. Server — with an embedded Crux node

The easiest way to get a fully working console is to let the server start a
Crux node for you. The Crux dependencies live in the `crux-jars` lein profile,
so it must be active:

```sh
lein with-profile +crux-jars run -m crux-ui-server.main
```

Configuration is read from `crux-console-conf.edn` in the working directory
(see `crux-console-conf.sample.edn`). For local dev with an embedded node use:

```edn
{:console/frontend-port      5000
 :console/embed-crux         true
 :console/routes-prefix      "/console"
 :console/hide-features      #{:features/attribute-history}
 :console/crux-node-url-base "localhost:8080"
 :console/crux-http-port     8080}
```

Then open <http://localhost:5000/console>. Smoke-test with a transaction

```clojure
[[:crux.tx/put {:crux.db/id :hello :title "world"}]]
```

followed by a query

```clojure
{:find [e] :where [[e :crux.db/id _]]}
```

The embedded node persists to `./data/` (RocksDB) — delete that directory for
a fresh database.

All config keys can also be passed as CLI flags after `--`
(e.g. `-- --embed-crux true --frontend-port 5001`); values are parsed with
`read-string`, so quote strings: `--crux-node-url-base '"localhost:8080"'`.

### Gotchas

- **`:crux-node-url-base` must NOT have the `/crux` suffix for local dev.**
  The default (`localhost:8080/crux`) is for the nginx reverse-proxy
  deployment described in the readme, where nginx rewrites `/crux` away.
  Against an embedded node (which serves its API at the root of port 8080)
  the `/crux` prefix produces `400 Bad Request` on every frontend request.
- **Service worker caching.** The console registers a service worker that
  caches the HTML, and the Crux node URL is baked into that HTML as a
  `data-crux-base-url` attribute. After changing config, hard-reload; if the
  browser still hits stale URLs, unregister the service worker
  (DevTools → Application → Service Workers) and reload.
- Pointing the console at an external Crux node? The URL must be reachable
  from the **browser** (not just the server) and the node must send CORS
  headers (the embedded node is started with permissive CORS —
  see `src/crux_ui_server/crux_auto_start.clj`).

## Sample data & querying

The database starts empty — the console ships with example **generators**
(`src/crux_ui/logic/example_queries.cljs`), not preloaded data. The built-in
dataset is a stock-market domain you load from the examples strip in the UI:

- **`:crux.tx/put`** — inserts 16 stock exchanges (NYSE, NASDAQ + its European
  subsidiaries, LSE, Euronext, …) and 50 random tickers with `:ticker/price`
  and `:ticker/market` references. Click it, then hit **Run Query**.
- **`put with valid time`** — writes ~500 days of price history for one ticker
  (derived from real Amazon closing prices, see `example_txes_amzn.cljs`).
  Load this to make the bitemporal features (time controls, history charts)
  interesting.

With data in place, try the query presets:

| Preset                | Demonstrates                                              |
|-----------------------|-----------------------------------------------------------|
| simple query          | basic Datalog: `{:find [e p] :where [[e :ticker/price p]]}` |
| join                  | joins across entities, `:order-by`, `:limit`, `:offset`   |
| rules and args        | parameterized queries (`:args`) and Datalog `:rules`      |
| full-results          | `:full-results? true` — return whole documents            |
| full-results with refresh | `:ui/poll-interval-seconds?` — console re-runs the query on an interval |
| delete / evict        | `:crux.tx/delete` (tombstone) vs `:crux.tx/evict` (erase) |

The editor auto-detects input type: an EDN **map** is a query, a **vector** is
a transaction. Use the time controls (datepickers / sliders) to run a query at
a different valid time / transaction time against the history data.

Tips:

- Entity-history charts are behind the `:features/attribute-history` feature,
  which the sample config hides — remove it from `:console/hide-features` and
  restart to enable them.
- You can load your own preset list with the URL param
  `?examples-gist=<raw-gist-url>` pointing to an EDN file of
  `{:title ... :query ...}` maps (format in the readme).

## HTTP API

The console server exposes one JSON-free, EDN-in/EDN-out endpoint of its own
(everything else is the Crux node's REST API, which the browser calls
directly):

### `POST <routes-prefix>/api/query`

Runs a Datalog query against the Crux node (server-side, via
`:console/crux-http-port`) and returns the results as an EDN **list** `(...)`
— unlike the Crux node's own `/query`, which returns a set `#{...}` for
unordered queries and a vector `[...]` for `:order-by` queries.

The body may be either the bare query map or the `{:query {...}}` wrapping
that the Crux node's `/query` endpoint expects — both are accepted:

```sh
curl -X POST http://localhost:5000/console/api/query \
  -H "Content-Type: application/edn" \
  -d '{:find [e p] :where [[e :ticker/price p]] :order-by [[p :asc]] :limit 3}'
# => ([:ids/fashion-ticker-21 2] [:ids/industry-ticker-48 5] ...)
```

Errors come back as `400` with an EDN body `{:error "..."}`.
Handler: `::api-query` in `src/crux_ui_server/main.clj`.

## Tests

Frontend tests live in `test/` (`*_test.cljs`, run by
`crux-console.test-runner` via shadow-cljs' `:browser-test` target):

```sh
node_modules/.bin/shadow-cljs watch test
```

then open <http://localhost:4001> — results render in the browser and re-run
on save.

There is no backend (clj) test suite at the moment.

## Production build

```sh
lein build                                  # yarn install + shadow-cljs release app
lein with-profile base:crux-jars uberjar    # builds both jars
```

The uberjar step produces:

- `target/crux-console-skimmed.jar` — console only; expects an external Crux
  node (`:console/embed-crux false`)
- `target/crux-console.jar` — bundles Crux; can run with `--embed-crux true`

Run with:

```sh
java -jar target/crux-console.jar --embed-crux true
```

`make all` is an equivalent shortcut (clean, install, release build, uberjar),
and `lein build-ebs` additionally packs an AWS Elastic Beanstalk bundle
(see `dev/build-ebs.sh`).

## Code style / architecture notes

- Frontend state management is re-frame: events and subscriptions are under
  `src/crux_ui/events/` and `src/crux_ui/subs.cljs`; views under
  `src/crux_ui/views/` (the query screen is `views/query/`).
- Query parsing/classification (query vs transaction) lives in
  `src/crux_ui/logic/query_analysis.cljs` — a good place to start reading.
- Server routing is bidi, defined in `src/crux_ui_server/main.clj`; HTML is
  generated server-side by `src/crux_ui_server/pages.clj` (page-renderer),
  which is also where frontend runtime config is injected as `data-*`
  attributes on `<html>`.
