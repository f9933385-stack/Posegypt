# Open engineering and business approvals

| ID | Topic | Provisional behavior | Needs approval before release |
|---|---|---|---|
| DEC-01 | Inventory costing | WAC by warehouse with integer-cost rounding | Verify branch-wide vs warehouse-wide cost, negative stock and exact returns rounding |
| DEC-02 | Inventory lots/FEFO | Lot table placeholder only; no automatic sale allocation | Define physical vs virtual FEFO and expiry restriction according to law |
| DEC-03 | Invoice tax mapping | Nonzero `tax_rate_bp` on product only | Verify current Egyptian e-receipt/e-invoice procedures, exemptions and registry |
| DEC-04 | Branch architecture | Each deployment has local DB; DB currently permits multiple branch records | Separate database per branch, central entity IDs and inter-branch transfer protocol |
| DEC-05 | Synchronization | Append-only local outbox; no relay | Choose cloud provider and design inbox/conflict/idempotency/reconciliation |
| DEC-06 | Licensing | No license gate active | Annual 500 EGP per device, signed token lifecycle, renewal, transfer and read-only lock |
| DEC-07 | Backups | No backup workflow | Encrypted SQLite snapshot + verified restore + rotation + Google Drive consent |
| DEC-08 | Hardware | No printer/scale integration | Test exact supported thermal printers, labels, readers, scales and drivers |
| DEC-09 | LAN security | Loopback default; opt-in insecure LAN mode | TLS trust/bootstrap, device pairing, token rotation and revocation |
| DEC-10 | Promotions | No promo engine | Promotion priority/exclusions/price floor approval policies |
| DEC-11 | Tax/returns accounting | Simple credits and COGS reversal | Check B2B/B2C documents and rounding of repeated partial returns |
| DEC-12 | Branch/cash controls | Cash balances may become negative at ledger level | Opening float, shift close, cash ceiling, tender reconciliation, refunds |

A decision becomes *approved* only after owner sign-off and new automated acceptance cases. This code base does not silently infer approval from this document.
