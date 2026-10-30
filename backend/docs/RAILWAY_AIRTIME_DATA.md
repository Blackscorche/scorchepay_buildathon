# Railway airtime and data setup

The backend already contains an SMEPlug adapter for airtime and data. Do not put provider keys in the app, Git, build arguments, or a public URL. Set them as Railway service variables.

Required service variables for a live provider pilot:

- `VTU_PROVIDER=smeplug`
- `SMEPLUG_API_KEY=<new private key>`
- `BILLS_PROVIDER=off` while electricity and TV have no live adapter
- `DEV_SIMULATE_PAYMENTS=false`
- `PUBLIC_URL=https://<public Railway domain>`
- Database, JWT, admin token, Bitcoin node, pricing, and other required settings from `.env.example`

The server refuses live SMEPlug vending with simulated payments unless `LIVE_PROVIDER_TEST_USER_ID` is set to the UUID of the sole tester. In that private test mode, the simulate-payment endpoint requires that tester’s signed-in token and only accepts orders owned by that tester. Set `DEV_SIMULATE_PAYMENTS=true` only for this controlled test. Each simulated payment can spend real provider-wallet naira. The current Bitcoin backend supports Signet and regtest only, so deploying these variables does not by itself create a production payment flow. Provider vending spends real naira from the SMEPlug wallet. Use a small, controlled pilot after payment settlement and provider balance checks are verified. Do not use the public development simulation endpoint on a service with live provider funds.

For a two-phone Pay for me test, the shared URL must resolve from the other phone. The web page can generate an invoice and show order status, but the current local demo wallet is not a real payer for backend invoices. Test settlement with a compatible test-network Lightning wallet or the isolated regtest flow before claiming a successful cross-device payment.
