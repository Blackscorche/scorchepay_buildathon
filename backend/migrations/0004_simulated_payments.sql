-- Development only (DEV_SIMULATE_PAYMENTS): orders marked paid without a
-- Lightning payment, so there's nothing to claim or fail back.
ALTER TABLE orders ADD COLUMN simulated BOOLEAN NOT NULL DEFAULT false;
