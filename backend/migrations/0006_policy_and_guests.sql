-- Spending policy: rules the owner sets for themselves, checked on every
-- payment (orders, requotes, bill links and the bill helper).
CREATE TABLE user_policies (
    user_id          UUID PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    -- Naira. NULL means no limit of this kind.
    per_payment_cap  BIGINT CHECK (per_payment_cap > 0),
    daily_cap        BIGINT CHECK (daily_cap > 0),
    -- When true, payments only go to numbers on the trusted list.
    trusted_only     BOOLEAN NOT NULL DEFAULT false,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Numbers (phones, meters, smartcards) the owner has marked as safe, with a
-- name to refer to them by ("mama", "my meter").
CREATE TABLE trusted_targets (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    label       TEXT NOT NULL,
    target      TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, target)
);

-- Every policy decision worth showing: what was blocked and why, and what
-- was allowed while a policy was active. Targets are stored masked.
CREATE TABLE policy_events (
    id           BIGSERIAL PRIMARY KEY,
    user_id      UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    source       TEXT NOT NULL,
    outcome      TEXT NOT NULL,
    reason       TEXT,
    message      TEXT NOT NULL,
    biller_name  TEXT,
    title        TEXT,
    target       TEXT,
    amount       BIGINT,
    order_id     TEXT
);
CREATE INDEX policy_events_user_at ON policy_events (user_id, at DESC);

-- Accounts made by the "ask for a top-up" page: a verified phone number with
-- no PIN yet. Signing up with the same contact later claims the account.
ALTER TABLE users ADD COLUMN is_guest BOOLEAN NOT NULL DEFAULT false;
