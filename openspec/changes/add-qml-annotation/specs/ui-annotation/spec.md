## ADDED Requirements

### Requirement: Server-only serve mode (no reverse proxy)

The `serve` command SHALL support running the `/__annotate/*` callback server **without** a reverse
proxy target, so non-web surfaces (e.g. the in-process QML overlay) can use the same callback
endpoints and long-poll `poll` loop. The existing proxying behavior is unchanged when a target is
given.

#### Scenario: Serve without a target
- **WHEN** `serve` is run with no `--target`/`ANNOTATE_TARGET` (e.g. `serve --server-only`)
- **THEN** it starts the `/__annotate/*` callback server (`submit`, `poll`, `reply`, `messages`,
  `shutdown`), binds loopback, writes the session file, and prints its base URL — while performing
  no reverse proxying and injecting no overlay

#### Scenario: Proxy mode is unchanged when a target is given
- **WHEN** `serve --target <url>` is run
- **THEN** it behaves exactly as before (reverse proxy + overlay injection + HMR tunnel + callback
  routes), with no change from the server-only addition

#### Scenario: Session file is discoverable by an external overlay
- **WHEN** the server-only mode is running
- **THEN** a client (such as the QML overlay's Python bridge) can read the session file / base URL
  and POST to `/__annotate/submit` and GET `/__annotate/messages` identically to the web overlay
