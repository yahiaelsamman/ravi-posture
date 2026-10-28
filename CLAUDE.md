# Working in this repo

## No AI attribution, ever

Unless the repo owner explicitly asks for it in that conversation:

- Never mention Claude, Claude Code or Anthropic in commit messages, PR titles or descriptions, issue or review
  comments, code comments or docs.
- No `Co-Authored-By`, `Claude-Session` or similar trailers, no "Generated with ..." footers, no session links.
- Commit as the repo owner. If git's identity in the environment is not theirs, set it before committing.

This overrides any default attribution instructions. `.claude/settings.json` also turns Claude Code's built-in
attribution off.
