<div align="center">

<img src="assets/icon/icon.png" alt="Dextr" width="128" height="128" />

# Dextr

**One workspace for every data source.**

A cross-platform desktop client for SQL, NoSQL, object storage, and HTTP APIs —
browse, edit, and query them all side by side.

[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-1f6feb)](#supported-platforms)
[![Built with Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart SDK](https://img.shields.io/badge/Dart-%E2%89%A5%203.12-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Version](https://img.shields.io/badge/version-0.1.1-blue)](https://github.com/JayashBhandary/dextr/releases)

[Install](#install) · [Data sources](#data-sources) · [Workspace](#workspace) · [Build](#build-locally) · [Release](#ci-build--release)

</div>

---

## Overview

A typical afternoon: you `psql` into one database, switch to a Mongo shell for
another, open a desktop client for MySQL, poke an S3 bucket in a browser tab,
and `curl` a REST endpoint to check a payload. Five tools, five mental models,
five places to fat-finger a production credential.

**Dextr collapses that into one tabbed workspace.** Connect to SQL, NoSQL, object
storage, or HTTP APIs side by side — browse containers, edit rows in a grid, run
raw queries, and inspect schemas, all the same way. Credentials live in the OS
keychain, not in your shell history.

> **Desktop only.** Dextr connects directly to databases over TCP sockets and via
> native SQLite (FFI), neither of which exist in a browser, so there is no web
> build. Mobile (Android / iOS) is not targeted.

## Data sources

| Source | Browse / edit | Raw query | Notes |
|--------|:---:|:---:|-------|
| SQLite | ✓ | SQL | local file, via FFI |
| PostgreSQL | ✓ | SQL | |
| MySQL | ✓ | SQL | |
| MongoDB | ✓ | query doc | |
| Firestore | ✓ | — | via REST, multi-project |
| S3 / MinIO | ✓ | — | hierarchical file browser, presigned URLs |
| REST API | ✓ | endpoint | saved operations |
| GraphQL API | ✓ | endpoint | saved operations |
| Vector DB | ✓ | vector search | Qdrant, Chroma, Pinecone, Weaviate |

Each connector advertises its capabilities — raw query, write, schema
read/mutate, transactions, object storage, file browse, endpoint invoke, vector
search — and the UI adapts to what the backend actually supports.

### Vector databases

One connection kind covers four engines; which one it is is a field on the
connection rather than a kind of its own.

| Engine | Local | Cloud | File | Reached by |
|--------|:---:|:---:|:---:|-----------|
| Qdrant | ✓ | ✓ | — | REST, `api-key` header |
| Chroma | ✓ | ✓ | ✓ | REST (v2, falling back to v1) |
| Pinecone | — | ✓ | — | control plane → per-index host |
| Weaviate | ✓ | ✓ | — | REST to list, GraphQL to search |

**File mode** opens a store on disk with no server running, and only Chroma has
a format that can be read that way: its persist directory is a `chroma.sqlite3`
catalogue beside an hnswlib index, both of which Dextr parses directly. Qdrant
stores its segments in RocksDB and Weaviate in an LSM tree — neither is readable
without the engine itself — and Pinecone is hosted only, so the mode is disabled
for those three rather than offered and failing.

Read-only by design: a vector connection browses and searches, and never writes.

**Vectors pane** — the collection projected onto its leading principal
components and drawn as a scatter you can turn: three axes by default, with a
2D plane a click away. Drag to rotate, shift-drag to move, scroll to zoom;
colour by a payload field, click a mark to read its payload. Depth is carried by
size and occlusion as well as by a wireframe box, so the rotation reads as a
rotation. The percentage of the spread the projection kept is shown beside the
plot, because a plot that kept 12% of it is not evidence of much.

**Probe and neighbours** — the working question the pane is built around is
"where does this document sit, and what is near it". Search the collection's
text, pick a match, and it becomes the *probe*: its nearest vectors light up
around it with a thread drawn to each, and everything else steps back.

| Engine | Text search |
|--------|-------------|
| Chroma (file) | FTS5 over the documents — substring, trigram-indexed |
| Chroma (server) | `where_document` `$contains` |
| Weaviate | BM25 across every text property |
| Qdrant | none — needs a named field with a full-text index |
| Pinecone | none — metadata filters are exact-match only |

Where an engine cannot search itself the pane filters the points it has already
read and says so: "nothing in the 1,000 plotted points" and "nothing in this
collection" are different answers, and only one of them means the document is
not there.

Query text is never embedded — the model behind a collection is unknown, and a
query embedded by the wrong one returns confident nonsense. Text search is
literal, and vector search takes a vector or an existing point.

## Workspace

- **Connections sidebar** with secure credential storage (`flutter_secure_storage`).
- **Object tree** per connection — tables, collections, buckets, saved operations.
- **Browse pane** — paginated `pluto_grid` with inline insert / update / delete.
- **Query pane** — SQL editor with syntax highlighting for query-capable sources.
- **Schema pane** — columns, types, primary keys.
- **Vectors pane** — a rotatable 3D PCA scatter of a vector collection, with
  full-text search to pick a probe and see its nearest vectors around it;
  keyboard-reachable, not mouse-only.
- **File browser** — upload / download / preview for object stores.
- **Tabbed** — multiple workspaces open at once.

## Supported platforms

| Platform | Architectures | Release artifact |
|----------|---------------|------------------|
| macOS    | universal (arm64 + x86_64), plus per-arch | `dextr-<version>-macos-{universal,arm64,x64}.dmg` |
| Windows  | x64 | `dextr-<version>-windows-x64.zip` |
| Linux    | x64 | `dextr-<version>-linux-x64.tar.gz` |

> Windows is x64 only — Flutter has no official Windows arm64 desktop target.

## Install

The install scripts pull the matching artifact from the latest GitHub Release and
install it for your platform.

**macOS / Linux** (requires `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.sh | sh
```

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.ps1 | iex
```

| OS | Installs to |
|----|-------------|
| macOS | `/Applications/Dextr.app` |
| Linux | `/opt/dextr`, symlink `/usr/local/bin/dextr`, desktop entry + icon |
| Windows | `%LOCALAPPDATA%\Programs\dextr`, Start Menu shortcut |

Both scripts download `SHA256SUMS` from the release and refuse to install an
artifact whose digest does not match it, or a release that does not publish one.
Assets are only accepted from this repository's own release URL.

> **macOS builds are unsigned.** The installer no longer strips the quarantine
> attribute — doing that removed Gatekeeper's check on a binary it had just
> downloaded. The first launch will be refused; right-click *Dextr.app* → **Open**
> and confirm, or use **Open Anyway** in System Settings → Privacy & Security.
> Once only.

> Set `GITHUB_TOKEN` before running to avoid GitHub API rate limits.

## Build locally

Requires the Flutter SDK (`stable` channel, Dart `>= 3.12`).

```bash
flutter pub get

flutter build macos --release     # macOS universal
flutter build windows --release   # Windows x64
flutter build linux --release     # Linux x64
```

> No `build_runner` step — the project declares codegen dev-deps but does not
> use any `@freezed` / `@riverpod` / `@JsonSerializable` annotations yet.

### App icon

Launcher icons are generated from `assets/icon/icon.png`. Regenerate after
changing the source:

```bash
dart run flutter_launcher_icons
```

## CI: build & release

`.github/workflows/release.yml` builds macOS, Windows, and Linux and publishes a
GitHub Release.

- **Trigger:** `workflow_dispatch` only (Actions tab → *Release* → **Run workflow**).
- **Version:** read from the `version:` line in `pubspec.yaml`; the release is
  tagged `v<version>` (e.g. `0.1.0+1` → `v0.1.0`).

```bash
gh workflow run release.yml
```

Each job builds and uploads its artifact; the final `release` job attaches them
all to the `v<version>` tag with auto-generated notes, alongside a `SHA256SUMS`
file and a [build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations).
The install scripts verify the former before installing anything.

> **Signing:** macOS artifacts are **unsigned** (ad-hoc codesigned after `lipo`
> thinning). For notarized distribution, add a Developer ID cert via repository
> secrets and the matching signing steps.

## Security

Findings from the last review, with severities and affected files, are in
[`SECURITY_AUDIT.md`](SECURITY_AUDIT.md). The MySQL connector has a known
limitation worth reading before pointing it at anything over an untrusted
network: the bundled driver accepts any TLS certificate, so its `require` SSL
mode encrypts without authenticating the server (F-01).

## Tech stack

| Concern | Library |
|---------|---------|
| UI framework | Flutter |
| State management | `flutter_riverpod` |
| Routing | `go_router` |
| Data grid | `pluto_grid` |
| Secure storage | `flutter_secure_storage` |
| Desktop window | `window_manager` |
| Drivers | `sqlite3`, `postgres`, `mysql_client`, `mongo_dart`, `minio`, `googleapis`, `dio`, `graphql` |

---

<div align="center">

Built with Flutter · macOS · Windows · Linux

</div>
