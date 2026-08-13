# CR-EXT-001 — superseded

Filed 2026-07-25 by the extension worker as a standalone file, before
`docs/intake/CHANGE-REQUESTS.md` existed. Never triaged.

**Superseded by CR-002 in `docs/intake/CHANGE-REQUESTS.md`**, which re-files
the same four items in register form and revises three of them against the
`tools/intake` CLI that has since landed on main:

- the envelope question is settled by the implementation (not breaking, as
  this filing cautioned — the CLI already envelopes every `--json` command);
- the schema-version proposal is corrected (`schema` ships as an integer, not
  a semver string) and gains the additive-change problem that follows from
  that;
- the `E_NO_CLI` item is cross-referenced to the tools worker's CR-001.5,
  which reached the same conclusion independently.

Original text: `git show 519b0ca:docs/intake/CR-EXT-001-doc03.md`.
