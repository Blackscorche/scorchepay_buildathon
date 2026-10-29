-- Accounts. KYC tier and status are set only by the backend (Mono Prove
-- webhooks, or an admin), never by the app.
CREATE TABLE users (
    id              UUID PRIMARY KEY,
    username        TEXT NOT NULL UNIQUE,
    display_name    TEXT NOT NULL,
    -- Verified phone number or email from sign-up.
    contact         TEXT NOT NULL UNIQUE,
    pin_hash        TEXT NOT NULL,
    kyc_tier        INT  NOT NULL DEFAULT 0,
    kyc_status      TEXT NOT NULL DEFAULT 'unverified',
    failed_logins   INT  NOT NULL DEFAULT 0,
    locked_until    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Sign-up OTPs. Verifying one issues a sign-up token, spent by sign-up.
CREATE TABLE otp_challenges (
    id              UUID PRIMARY KEY,
    contact         TEXT NOT NULL,
    code_hash       TEXT NOT NULL,
    attempts        INT  NOT NULL DEFAULT 0,
    expires_at      TIMESTAMPTZ NOT NULL,
    signup_token    TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX otp_challenges_contact ON otp_challenges (contact);

-- Mono Prove sessions, looked up by our reference when its webhook arrives.
CREATE TABLE kyc_sessions (
    reference       TEXT PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users (id),
    provider        TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per purchase, for its whole life (docs/VTU.md). A requote
-- replaces the quote columns and the invoice in place. Expiry isn't
-- stored: an awaitingPayment order past expires_at reads as expired.
CREATE TABLE orders (
    id                  TEXT PRIMARY KEY,
    user_id             UUID NOT NULL REFERENCES users (id),
    status              TEXT NOT NULL,
    category            TEXT NOT NULL,
    biller_id           TEXT NOT NULL,
    biller_name         TEXT NOT NULL,
    title               TEXT NOT NULL,
    target              TEXT NOT NULL,
    option_id           TEXT,
    option_name         TEXT,
    plan_id             TEXT,
    plan_name           TEXT,
    -- Set for free-amount billers only, as the app sent it.
    requested_amount    BIGINT,
    customer_name       TEXT,
    amount              BIGINT NOT NULL,
    currency            TEXT NOT NULL,
    sats                BIGINT NOT NULL,
    rate                DOUBLE PRECISION NOT NULL,
    invoice             TEXT NOT NULL,
    -- The current invoice's hash and preimage. Invoices are claimed by
    -- hand (ldk-node receive_for_hash), only while they're current.
    payment_hash        TEXT NOT NULL UNIQUE,
    preimage            TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL,
    paid_at             TIMESTAMPTZ,
    fulfil_started_at   TIMESTAMPTZ,
    -- Who delivers it and their codes for the biller and plan, fixed at
    -- quote time so catalog changes can't alter a paid order.
    provider            TEXT NOT NULL,
    biller_code         TEXT NOT NULL,
    plan_code           TEXT,
    provider_ref        TEXT,
    receipt             JSONB,
    failure_reason      TEXT,
    -- Set when the provider's answer was lost (timeout): someone checks
    -- the provider's dashboard before refunding or completing it.
    needs_review        BOOLEAN NOT NULL DEFAULT false,
    refund_invoice      TEXT,
    refund_payment_id   TEXT,
    refund_requested_at TIMESTAMPTZ,
    refunded_at         TIMESTAMPTZ
);
CREATE INDEX orders_user_created ON orders (user_id, created_at DESC);
CREATE INDEX orders_status ON orders (status);
CREATE INDEX orders_refund_payment ON orders (refund_payment_id);
