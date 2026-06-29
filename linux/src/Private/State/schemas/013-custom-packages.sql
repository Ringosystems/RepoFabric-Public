-- Migration 013 (linux fork): custom_packages table.
--
-- Internal apps that the GUI publishes directly to the WinGet repo
-- without an upstream tracking source. Roughly mirrors subscription but
-- with no track/pinned_version semantics and with the full v1.6.0
-- manifest snapshot stored as JSON in manifest_json so the "Edit and
-- republish" flow can repopulate the wizard.

BEGIN;

CREATE TABLE IF NOT EXISTS custom_packages (
    custom_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    package_id             TEXT NOT NULL,
    package_name           TEXT,
    publisher              TEXT,
    -- Most recently published version (string, not a list; history lives
    -- in repo_catalog.versions_json).
    last_published_version TEXT,
    last_published_at      TEXT,
    -- Full WinGet manifest snapshot as the publish endpoint received it
    -- after JSON-schema validation. Stored verbatim so a republish can
    -- skip the form-rebuild step.
    manifest_json          TEXT NOT NULL,
    -- Operator metadata
    notes                  TEXT,
    created_by             TEXT NOT NULL,
    created_at             TEXT NOT NULL,
    modified_by            TEXT,
    modified_at            TEXT,
    created_via_gui        INTEGER NOT NULL DEFAULT 1
);

-- Same uniqueness shape as subscription: at most one custom_packages row
-- per package_id. Republishing a custom app updates the row in place.
CREATE UNIQUE INDEX IF NOT EXISTS ux_custom_packages_pkg
    ON custom_packages (package_id);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '13')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
