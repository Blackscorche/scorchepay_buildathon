-- One profile photo per user. `version` changes on every upload and is part
-- of the photo's URL, so clients never show a stale cached copy.
CREATE TABLE profile_photos (
    user_id      UUID PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    version      TEXT NOT NULL,
    content_type TEXT NOT NULL,
    data         BYTEA NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
