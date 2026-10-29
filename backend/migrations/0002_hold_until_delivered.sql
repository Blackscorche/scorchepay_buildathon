-- Payments are held (not claimed) until the provider delivers the bill.
-- These record what's held, so it can be claimed or failed back later.
ALTER TABLE orders ADD COLUMN held_msat BIGINT;
-- Block height after which the held payment can't be claimed any more.
ALTER TABLE orders ADD COLUMN claim_deadline INT;
