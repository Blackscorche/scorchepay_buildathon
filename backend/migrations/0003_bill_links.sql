-- Bill links: a user asks someone else (e.g. family abroad) to pay one
-- bill. Anyone with the link can pay it from any Lightning wallet; the
-- bill is delivered to the user's target. Each payment attempt is an
-- ordinary order owned by the user, so limits, holding and delivery work
-- exactly as for orders the user pays themselves.
CREATE TABLE bill_links (
    id              TEXT PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users (id),
    -- The OrderRequest to place when someone pays.
    request         JSONB NOT NULL,
    title           TEXT NOT NULL,
    category        TEXT NOT NULL,
    biller_name     TEXT NOT NULL,
    target          TEXT NOT NULL,
    amount          BIGINT NOT NULL,
    note            TEXT,
    -- The current payment attempt, if anyone has opened an invoice.
    order_id        TEXT REFERENCES orders (id),
    cancelled_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL
);
CREATE INDEX bill_links_user_created ON bill_links (user_id, created_at DESC);
