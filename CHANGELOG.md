# Changelog

Notable changes to the SQL Server migration tool are documented here. Versions
follow semantic versioning.

## 1.0.0 - 2026-10-06

Initial published application release.

- Added PowerShell and dbatools workflows for database discovery, validation,
  backup, restore, and post-migration checks.
- Added a secure HTTPS browser interface with sequential migration plans,
  per-database overwrite decisions, pause/resume/stop controls, and live
  progress events.
- Added full-data and schema-only migration modes.
- Added isolated striped backups, capacity preflight, migration state, and
  HTML/CSV reports.
- Added source-side `COPY_ONLY` backup behavior and documented its backup
  history, CPU, and I/O effects.
- Added automated tests and operational documentation.
