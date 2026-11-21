# Repository conventions

- Commit messages end at their own last line: no "Generated with", no AI
  attribution, no co-author trailers of any kind.
- The live simulator session is the product: keep `README.md` and
  `SECURITY.md` accurate when behaviour changes.
- Scripts under `scripts/ios-simulator/` must stay bash 3.2 compatible (macOS
  runners have no `mapfile` and no coreutils `timeout`).
