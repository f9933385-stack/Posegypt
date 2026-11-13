#!/usr/bin/env python3
"""Read-only accounting + inventory consistency audit of a Kasher branch DB.

Run this against an offline SQLite database or an SQLite-backed copy. This tool
checks structural integrity and independently reconciles important ledger
invariants; it does NOT certify compliance or replace a financial audit.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path


def audit(db_file: str) -> dict:
    path = Path(db_file)
    if not path.is_file():
        raise FileNotFoundError(f"Database not found: {path}")
    con = sqlite3.connect(f"file:{path.resolve().as_posix()}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    result = {"database": path.name, "status": "pass", "checks": [], "errors": []}

    def check(name: str, sql: str, max_rows: int = 20) -> None:
        rows = [dict(x) for x in con.execute(sql).fetchmany(max_rows)]
        result["checks"].append({"name": name, "passed": not bool(rows), "violations": rows})
        if rows:
            result["status"] = "fail"
            result["errors"].append(name)

    try:
        check("sqlite_integrity", "SELECT integrity_check AS issue FROM pragma_integrity_check WHERE integrity_check <> 'ok'")
        check("foreign_key_integrity", "SELECT * FROM pragma_foreign_key_check")
        check("double_entry_balance", """
          SELECT e.id, SUM(l.debit_minor-l.credit_minor) AS imbalance_minor
          FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
          GROUP BY e.id HAVING SUM(l.debit_minor-l.credit_minor)<>0
        """)
        check("empty_journal_entry", """
          SELECT e.id FROM journal_entries e LEFT JOIN journal_lines l ON l.entry_id=e.id
          WHERE l.entry_id IS NULL
        """)
        check("stock_qty_reconciliation", """
          SELECT s.branch_id, s.warehouse_id, s.product_id, s.qty_milli,
          COALESCE((SELECT SUM(m.qty_change_milli) FROM inventory_movements m
            WHERE m.branch_id=s.branch_id AND m.warehouse_id=s.warehouse_id
            AND m.product_id=s.product_id),0) AS movement_qty_milli
          FROM stock_balances s WHERE s.qty_milli <> COALESCE((
          SELECT SUM(m.qty_change_milli) FROM inventory_movements m
          WHERE m.branch_id=s.branch_id AND m.warehouse_id=s.warehouse_id
          AND m.product_id=s.product_id),0)
        """)
        check("stock_value_reconciliation", """
          SELECT s.branch_id, s.warehouse_id, s.product_id, s.cost_minor,
          COALESCE((SELECT SUM(m.cost_change_minor) FROM inventory_movements m
            WHERE m.branch_id=s.branch_id AND m.warehouse_id=s.warehouse_id
            AND m.product_id=s.product_id),0) AS movement_cost_minor
          FROM stock_balances s WHERE s.cost_minor <> COALESCE((
          SELECT SUM(m.cost_change_minor) FROM inventory_movements m
          WHERE m.branch_id=s.branch_id AND m.warehouse_id=s.warehouse_id
          AND m.product_id=s.product_id),0)
        """)
        check("orphan_movements", """
          SELECT m.id FROM inventory_movements m LEFT JOIN stock_balances s
          ON m.branch_id=s.branch_id AND m.warehouse_id=s.warehouse_id
          AND m.product_id=s.product_id WHERE s.product_id IS NULL
        """)
        # Only v3 branches have a separate, transactionally traced expiry-lot ledger.
        has_lots = con.execute("""
          SELECT 1 FROM sqlite_master WHERE type='table' AND name='batch_movements'
        """).fetchone() is not None
        if has_lots:
            check("tracked_product_lot_quantity", """
              SELECT s.branch_id, s.warehouse_id, s.product_id,
                s.qty_milli AS stock_qty_milli,
                COALESCE((SELECT SUM(b.qty_milli) FROM batches b
                  WHERE b.warehouse_id=s.warehouse_id
                  AND b.product_id=s.product_id),0) AS lot_qty_milli
              FROM stock_balances s JOIN products p ON p.id=s.product_id
              WHERE p.track_expiry=1 AND s.qty_milli<>COALESCE((
                SELECT SUM(b.qty_milli) FROM batches b
                WHERE b.warehouse_id=s.warehouse_id AND b.product_id=s.product_id),0)
            """)
            check("tracked_lot_movement_balance", """
              SELECT b.id,b.qty_milli AS stored_qty,
                COALESCE((SELECT SUM(m.qty_change_milli) FROM batch_movements m
                  WHERE m.batch_id=b.id),0) AS moved_qty
              FROM batches b JOIN products p ON p.id=b.product_id
              WHERE p.track_expiry=1 AND b.qty_milli<>COALESCE((
                SELECT SUM(m.qty_change_milli) FROM batch_movements m
                WHERE m.batch_id=b.id),0)
            """)
        has_stock_counts = con.execute("""
          SELECT 1 FROM sqlite_master WHERE type='table' AND name='stock_counts'
        """).fetchone() is not None
        if has_stock_counts:
            check("posted_stock_count_approval", """
              SELECT c.id,c.created_by,c.approved_by
              FROM stock_counts c
              WHERE c.status='posted' AND
                (c.approved_by IS NULL OR c.approved_at IS NULL
                 OR c.created_by=c.approved_by)
            """)
            check("posted_stock_count_missing_counts", """
              SELECT c.id,l.id AS line_id FROM stock_counts c
              JOIN stock_count_lines l ON l.count_id=c.id
              WHERE c.status='posted' AND l.counted_qty_milli IS NULL
            """)
            check("stock_count_variance_movement", """
              SELECT c.id,l.product_id,
                SUM(l.counted_qty_milli-l.expected_qty_milli) AS intended_delta,
                COALESCE((SELECT SUM(m.qty_change_milli)
                  FROM inventory_movements m
                  WHERE m.reference_type='stock_count'
                    AND m.reference_id=c.id AND m.product_id=l.product_id),0)
                  AS applied_delta
              FROM stock_counts c JOIN stock_count_lines l ON l.count_id=c.id
              WHERE c.status='posted'
              GROUP BY c.id,l.product_id
              HAVING intended_delta<>applied_delta
            """)
        has_shipments = con.execute("""
          SELECT 1 FROM sqlite_master WHERE type='table' AND name='branch_shipments'
        """).fetchone() is not None
        if has_shipments:
            check("branch_shipment_location", """
              SELECT s.id FROM branch_shipments s
              JOIN branches src ON src.id=s.source_branch_id
              JOIN branches dst ON dst.id=s.destination_branch_id
              JOIN warehouses w1 ON w1.id=s.source_warehouse_id
              JOIN warehouses w2 ON w2.id=s.destination_warehouse_id
              JOIN products p ON p.id=s.product_id
              WHERE src.tenant_id<>s.tenant_id
                 OR dst.tenant_id<>s.tenant_id
                 OR p.tenant_id<>s.tenant_id
                 OR w1.branch_id<>s.source_branch_id
                 OR w2.branch_id<>s.destination_branch_id
            """)
            check("branch_shipment_movement", """
              SELECT s.id,s.qty_milli,s.status
              FROM branch_shipments s
              WHERE COALESCE((SELECT SUM(-m.qty_change_milli)
                FROM inventory_movements m
                WHERE m.reference_type='branch_dispatch' AND m.reference_id=s.id),0)
                    <>s.qty_milli
                 OR COALESCE((SELECT SUM(m.qty_change_milli)
                FROM inventory_movements m
                WHERE m.reference_type='branch_receive' AND m.reference_id=s.id),0)
                    <> CASE WHEN s.status='received' THEN s.qty_milli ELSE 0 END
                 OR COALESCE((SELECT SUM(m.qty_change_milli)
                FROM inventory_movements m
                WHERE m.reference_type='branch_dispatch_cancel' AND m.reference_id=s.id),0)
                    <> CASE WHEN s.status='cancelled' THEN s.qty_milli ELSE 0 END
            """)
            check("branch_shipment_lot_trace", """
              SELECT s.id,s.qty_milli FROM branch_shipments s
              JOIN products p ON p.id=s.product_id
              WHERE p.track_expiry=1 AND s.qty_milli<>COALESCE((
                SELECT SUM(l.qty_milli) FROM branch_shipment_lots l
                WHERE l.shipment_id=s.id),0)
            """)
            check("branch_shipment_receiver_separation", """
              SELECT s.id FROM branch_shipments s
              WHERE s.status='received' AND
              (s.received_by IS NULL OR s.received_at IS NULL
                OR s.received_by=s.dispatched_by)
            """)
            check("branch_shipment_transit_value", """
              SELECT * FROM (
                SELECT
                  COALESCE((SELECT SUM(cost_minor) FROM branch_shipments
                    WHERE status='in_transit'),0) AS expected_minor,
                  COALESCE((SELECT SUM(debit_minor-credit_minor)
                    FROM journal_lines WHERE account='IN_TRANSIT'),0) AS ledger_minor
              ) WHERE expected_minor<>ledger_minor
            """)
        check("invalid_paid_amount", """
          SELECT id, total_minor,paid_minor FROM documents
          WHERE paid_minor<0 OR paid_minor>total_minor
        """)
        check("tenant_product_mismatch", """
          SELECT m.id, b.tenant_id AS branch_tenant, p.tenant_id AS product_tenant
          FROM inventory_movements m JOIN branches b ON b.id=m.branch_id
          JOIN products p ON p.id=m.product_id WHERE b.tenant_id<>p.tenant_id
        """)
    except sqlite3.DatabaseError as exc:
        result["status"] = "fail"
        result["errors"].append(f"Database error: {exc}")
    finally:
        con.close()
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", help="Existing branch SQLite database")
    parser.add_argument("--json", action="store_true")
    a = parser.parse_args()
    output = audit(a.database)
    if a.json:
        print(json.dumps(output, ensure_ascii=False, indent=2))
    else:
        for item in output["checks"]:
            print(("PASS" if item["passed"] else "FAIL") + " " + item["name"])
            if not item["passed"]:
                print("  Sample violations:", item["violations"][:3])
        print("AUDIT:", output["status"].upper())
    if output["status"] != "pass":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
