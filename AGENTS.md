# Release maintenance

- Bump the package version when preparing a requested release, not on every PR.
  `@version` in `mix.exs` is the source of truth.
- Fetch `origin/main` and tags; confirm the latest published version on Hex.
  Review the complete diff since its `vX.Y.Z` tag, not just recent PRs. Include
  only landed changes; identify pending dependencies instead of claiming them.
- Use a patch bump for compatible fixes. While pre-1.0, use a minor bump for new
  configuration or stricter defaults; call out compatibility effects explicitly.
- Add a matching `vX.Y.Z (Unreleased)` section to `CHANGELOG.md`, grouped by
  changed behavior, not an inventory of unchanged features. Include new defaults,
  option placement, migration notes, and limitations of the changes. Preserve
  historical entries. Set the actual date when releasing.
- Search tracked files for the old version; update current installation examples
  if present, not historical references. A package bump does not require editing
  `mix.lock` or dependency constraints. Update dependencies only when requested
  or needed by the change; check minimum supported versions before using new APIs.
- Follow `.github/workflows/ci.yml` for the supported runtime matrix and example
  checks; use the latest stable Elixir for formatting. Before a release PR, run:
  `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`,
  `mix test --warnings-as-errors`, `mix docs`, and `mix hex.build`.
  Inspect package contents; do not commit generated docs, builds, or archives.
- Preparing a release PR does not authorize merging, creating/pushing a tag,
  publishing to Hex, or creating a GitHub release. Get explicit approval first;
  the eventual `vX.Y.Z` tag must identify the approved release commit.
