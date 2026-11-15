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
        has_allocations = con.execute("""
          SELECT 1 FROM sqlite_master WHERE type='table' AND name='debt_allocations'
        """).fetchone() is not None
        if has_allocations:
            check("invoice_allocation_consistency", """
              SELECT a.id,a.document_id,a.payment_id FROM debt_allocations a
              LEFT JOIN payments p ON p.id=a.payment_id
              LEFT JOIN documents d ON d.id=a.document_id
              LEFT JOIN branches b ON b.id=a.branch_id
              WHERE p.id IS NULL OR d.id IS NULL OR b.id IS NULL
                 OR a.amount_minor<>p.amount_minor
                 OR p.document_id IS NOT NULL
                 OR p.branch_id IS NOT a.branch_id
                 OR p.party_id IS NOT a.party_id
                 OR d.branch_id IS NOT a.branch_id
                 OR d.party_id IS NOT a.party_id
                 OR d.tenant_id IS NOT b.tenant_id
                 OR d.state<>'posted'
                 OR (a.party_type='customer' AND
                       (d.kind<>'sale' OR p.direction<>'in'))
                 OR (a.party_type='supplier' AND
                       (d.kind<>'purchase' OR p.direction<>'out'))
            """)
        has_split_allocations = con.execute("""
          SELECT 1 FROM sqlite_master
          WHERE type='table' AND name='debt_allocation_lines'
        """).fetchone() is not None
        if has_split_allocations:
            check("split_allocation_consistency", """
              SELECT a.id,a.document_id,a.payment_id FROM debt_allocation_lines a
              LEFT JOIN payments p ON p.id=a.payment_id
              LEFT JOIN documents d ON d.id=a.document_id
              LEFT JOIN branches b ON b.id=a.branch_id
              WHERE p.id IS NULL OR d.id IS NULL OR b.id IS NULL
                 OR p.document_id IS NOT NULL
                 OR p.branch_id IS NOT a.branch_id
                 OR p.party_id IS NOT a.party_id
                 OR d.branch_id IS NOT a.branch_id
                 OR d.party_id IS NOT a.party_id
                 OR d.tenant_id IS NOT b.tenant_id
                 OR d.state<>'posted'
                 OR EXISTS(SELECT 1 FROM debt_allocations old
                           WHERE old.payment_id=a.payment_id)
                 OR (a.party_type='customer' AND
                       (d.kind<>'sale' OR p.direction<>'in'))
                 OR (a.party_type='supplier' AND
                       (d.kind<>'purchase' OR p.direction<>'out'))
            """)
            check("split_payment_amounts", """
              SELECT p.id,p.amount_minor,SUM(a.amount_minor) AS allocated_minor
              FROM payments p JOIN debt_allocation_lines a ON a.payment_id=p.id
              GROUP BY p.id HAVING p.amount_minor<>SUM(a.amount_minor)
            """)
        has_reconciliations = con.execute("""
          SELECT 1 FROM sqlite_master
          WHERE type='table' AND name='debt_reconciliations'
        """).fetchone() is not None
        if has_reconciliations:
            check("debt_reconciliation_review_controls", """
              SELECT r.id,r.payment_id,r.status
              FROM debt_reconciliations r
              LEFT JOIN payments p ON p.id=r.payment_id
              LEFT JOIN branches b ON b.id=r.branch_id
              WHERE p.id IS NULL OR b.id IS NULL
                 OR p.branch_id IS NOT r.branch_id
                 OR p.party_id IS NOT r.party_id
                 OR p.document_id IS NOT NULL
                 OR (r.party_type='customer' AND p.direction<>'in')
                 OR (r.party_type='supplier' AND p.direction<>'out')
                 OR (r.status='pending'
                    AND (r.reviewed_by IS NOT NULL OR r.reviewed_at IS NOT NULL))
                 OR (r.status<>'pending' AND
                    (r.reviewed_by IS NULL OR r.reviewed_at IS NULL
                      OR r.review_reason IS NULL
                      OR r.requested_by=r.reviewed_by))
            """)
            check("approved_debt_reconciliation_matches_allocations", """
              SELECT r.id,r.payment_id,p.amount_minor
              FROM debt_reconciliations r
              JOIN payments p ON p.id=r.payment_id
              WHERE r.status='approved' AND (
                (SELECT COUNT(*) FROM debt_reconciliation_lines l
                 WHERE l.reconciliation_id=r.id)=0
                OR (SELECT COALESCE(SUM(amount_minor),0)
                  FROM debt_reconciliation_lines l
                  WHERE l.reconciliation_id=r.id)<>p.amount_minor
                OR EXISTS(
                  SELECT 1 FROM debt_reconciliation_lines l
                  LEFT JOIN debt_allocation_lines a
                    ON a.payment_id=r.payment_id
                   AND a.document_id=l.document_id
                  WHERE l.reconciliation_id=r.id
                    AND (a.id IS NULL OR a.amount_minor<>l.amount_minor
                      OR a.party_id IS NOT r.party_id
                      OR a.branch_id IS NOT r.branch_id
                      OR a.party_type IS NOT r.party_type))
                OR (SELECT COUNT(*) FROM debt_allocation_lines a
                  WHERE a.payment_id=r.payment_id)<>
                    (SELECT COUNT(*) FROM debt_reconciliation_lines l
                      WHERE l.reconciliation_id=r.id)
                OR EXISTS(SELECT 1 FROM debt_allocations old
                  WHERE old.payment_id=r.payment_id)
              )
            """)
        has_credit_allocations = con.execute("""
          SELECT 1 FROM sqlite_master
          WHERE type='table' AND name='debt_credit_allocations'
        """).fetchone() is not None
        if has_credit_allocations:
            check("debt_credit_allocation_scope", """
              SELECT a.id,a.credit_document_id,a.document_id
              FROM debt_credit_allocations a
              LEFT JOIN documents src ON src.id=a.credit_document_id
              LEFT JOIN documents dst ON dst.id=a.document_id
              LEFT JOIN branches b ON b.id=a.branch_id
              WHERE src.id IS NULL OR dst.id IS NULL OR b.id IS NULL
                 OR src.state<>'posted' OR dst.state<>'posted'
                 OR src.branch_id<>a.branch_id OR dst.branch_id<>a.branch_id
                 OR src.party_id<>a.party_id OR dst.party_id<>a.party_id
                 OR (a.party_type='customer' AND
                     (src.kind<>'sale_return' OR dst.kind<>'sale'))
                 OR (a.party_type='supplier' AND
                     (src.kind<>'purchase_return' OR dst.kind<>'purchase'))
                 OR src.total_minor<=0 OR dst.total_minor<=0
                 OR length(trim(a.reason))<12
            """)
            check("debt_credit_source_overallocated", """
              SELECT src.id,src.total_minor,SUM(a.amount_minor) AS allocated_minor
              FROM documents src
              JOIN debt_credit_allocations a ON a.credit_document_id=src.id
              GROUP BY src.id
              HAVING SUM(a.amount_minor)>src.total_minor
            """)
            check("debt_credit_target_overallocated", """
              SELECT dst.id,dst.total_minor,dst.paid_minor,
                COALESCE((SELECT SUM(x.amount_minor) FROM debt_allocations x
                  WHERE x.document_id=dst.id),0) +
                COALESCE((SELECT SUM(x.amount_minor) FROM debt_allocation_lines x
                  WHERE x.document_id=dst.id),0) +
                COALESCE((SELECT SUM(x.amount_minor) FROM debt_credit_allocations x
                  WHERE x.document_id=dst.id),0) AS applied_minor
              FROM documents dst
              WHERE dst.kind IN ('sale','purchase') AND
                dst.paid_minor +
                COALESCE((SELECT SUM(x.amount_minor) FROM debt_allocations x
                  WHERE x.document_id=dst.id),0) +
                COALESCE((SELECT SUM(x.amount_minor) FROM debt_allocation_lines x
                  WHERE x.document_id=dst.id),0) +
                COALESCE((SELECT SUM(x.amount_minor) FROM debt_credit_allocations x
                  WHERE x.document_id=dst.id),0)>dst.total_minor
            """)
        has_drawers = con.execute("""
          SELECT 1 FROM sqlite_master
          WHERE type='table' AND name='cash_drawers'
        """).fetchone() is not None
        if has_drawers:
            check("cash_drawer_location", """
              SELECT d.id,d.branch_id FROM cash_drawers d
              LEFT JOIN branches b ON b.id=d.branch_id
              LEFT JOIN users u ON u.id=d.created_by
              WHERE b.id IS NULL OR u.id IS NULL
                 OR u.tenant_id<>b.tenant_id
            """)
            check("cash_shift_drawer_ownership", """
              SELECT s.id,s.drawer_id,s.user_id FROM cash_shifts s
              LEFT JOIN cash_drawers d ON d.id=s.drawer_id
              LEFT JOIN users u ON u.id=s.user_id
              WHERE s.drawer_id IS NOT NULL AND
                (d.id IS NULL OR d.branch_id<>s.branch_id OR
                 u.id IS NULL OR u.tenant_id<>(SELECT tenant_id
                   FROM branches WHERE id=s.branch_id))
            """)
            check("cash_shift_posting_integrity", """
              SELECT l.journal_entry_id,l.shift_id,l.cash_delta_minor
              FROM cash_shift_journal_links l
              LEFT JOIN journal_entries e ON e.id=l.journal_entry_id
              LEFT JOIN cash_shifts s ON s.id=l.shift_id
              LEFT JOIN cash_drawers d ON d.id=s.drawer_id
              WHERE e.id IS NULL OR s.id IS NULL OR d.id IS NULL
                 OR e.branch_id<>s.branch_id
                 OR d.branch_id<>s.branch_id
                 OR e.created_by<>s.user_id
                 OR e.created_at<s.opened_at
                 OR (s.closed_at IS NOT NULL AND e.created_at>s.closed_at)
                 OR COALESCE((SELECT SUM(j.debit_minor-j.credit_minor)
                   FROM journal_lines j
                   WHERE j.entry_id=e.id AND j.account='CASH'),0)
                   <>l.cash_delta_minor
            """)
            check("cash_shift_unattributed_cash", """
              SELECT e.id,e.branch_id,e.created_by,e.created_at
              FROM journal_entries e
              WHERE EXISTS(SELECT 1 FROM cash_drawers d
                WHERE d.branch_id=e.branch_id AND d.created_at<=e.created_at)
                AND EXISTS(SELECT 1 FROM journal_lines j
                  WHERE j.entry_id=e.id AND j.account='CASH'
                    AND (j.debit_minor<>0 OR j.credit_minor<>0))
                AND NOT EXISTS(SELECT 1 FROM cash_shift_journal_links l
                  WHERE l.journal_entry_id=e.id)
            """)
        has_transfers = con.execute("""
          SELECT 1 FROM sqlite_master
          WHERE type='table' AND name='cash_drawer_transfers'
        """).fetchone() is not None
        if has_transfers:
            check("cash_drawer_transfer_integrity", """
              SELECT t.id,t.branch_id,t.status FROM cash_drawer_transfers t
              LEFT JOIN cash_shifts src ON src.id=t.source_shift_id
              LEFT JOIN cash_shifts dst ON dst.id=t.destination_shift_id
              LEFT JOIN cash_drawers sd ON sd.id=src.drawer_id
              LEFT JOIN cash_drawers dd ON dd.id=dst.drawer_id
              LEFT JOIN branches b ON b.id=t.branch_id
              LEFT JOIN users maker ON maker.id=t.requested_by
              LEFT JOIN users reviewer ON reviewer.id=t.reviewed_by
              WHERE src.id IS NULL OR dst.id IS NULL
                 OR sd.id IS NULL OR dd.id IS NULL OR b.id IS NULL
                 OR src.branch_id<>t.branch_id
                 OR dst.branch_id<>t.branch_id
                 OR sd.branch_id<>t.branch_id
                 OR dd.branch_id<>t.branch_id
                 OR src.drawer_id=dst.drawer_id
                 OR src.user_id=dst.user_id
                 OR maker.id IS NULL OR maker.id<>src.user_id
                 OR maker.tenant_id<>b.tenant_id
                 OR length(trim(t.reason))<12
                 OR t.amount_minor<=0
                 OR t.requested_at<src.opened_at
                 OR t.requested_at<dst.opened_at
                 OR (t.status='pending' AND (
                   t.reviewed_by IS NOT NULL OR t.reviewed_at IS NOT NULL
                   OR t.review_reason IS NOT NULL
                   OR src.closed_at IS NOT NULL
                   OR dst.closed_at IS NOT NULL))
                 OR (t.status<>'pending' AND (
                   reviewer.id IS NULL OR t.reviewed_at IS NULL
                   OR t.review_reason IS NULL
                   OR length(trim(t.review_reason))<12
                   OR t.reviewed_at<t.requested_at))
                 OR (t.status IN ('approved','rejected')
                   AND reviewer.id<>dst.user_id)
                 OR (t.status='cancelled' AND reviewer.id<>src.user_id)
                 OR (t.status='approved' AND (
                   t.reviewed_at<src.opened_at OR t.reviewed_at<dst.opened_at
                   OR (src.closed_at IS NOT NULL
                     AND t.reviewed_at>src.closed_at)
                   OR (dst.closed_at IS NOT NULL
                     AND t.reviewed_at>dst.closed_at)))
            """)
        has_safes = con.execute("""
          SELECT 1 FROM sqlite_master
          WHERE type='table' AND name='cash_safe_drops'
        """).fetchone() is not None
        if has_safes:
            check("cash_safe_registration_scope", """
              SELECT safe.id,safe.branch_id,safe.created_by
              FROM cash_safes safe
              LEFT JOIN branches b ON b.id=safe.branch_id
              LEFT JOIN users u ON u.id=safe.created_by
              WHERE b.id IS NULL OR u.id IS NULL
                 OR u.tenant_id<>b.tenant_id
                 OR u.role NOT IN ('owner','manager')
                 OR NOT EXISTS (SELECT 1 FROM cash_drawers d
                   WHERE d.branch_id=safe.branch_id)
            """)
            check("cash_safe_drop_integrity", """
              SELECT d.id,d.safe_id,d.status,d.amount_minor
              FROM cash_safe_drops d
              LEFT JOIN cash_safes safe ON safe.id=d.safe_id
              LEFT JOIN branches b ON b.id=d.branch_id
              LEFT JOIN cash_shifts shift ON shift.id=d.source_shift_id
              LEFT JOIN cash_drawers drawer ON drawer.id=shift.drawer_id
              LEFT JOIN users maker ON maker.id=d.requested_by
              LEFT JOIN users reviewer ON reviewer.id=d.reviewed_by
              WHERE safe.id IS NULL OR b.id IS NULL
                 OR shift.id IS NULL OR drawer.id IS NULL
                 OR maker.id IS NULL
                 OR safe.branch_id<>d.branch_id
                 OR shift.branch_id<>d.branch_id
                 OR drawer.branch_id<>d.branch_id
                 OR shift.user_id<>d.requested_by
                 OR maker.tenant_id<>b.tenant_id
                 OR d.amount_minor<=0
                 OR length(trim(d.reason))<12
                 OR d.requested_at<shift.opened_at
                 OR (shift.closed_at IS NOT NULL
                   AND d.requested_at>shift.closed_at)
                 OR (d.status='pending' AND (
                   d.reviewed_by IS NOT NULL OR d.reviewed_at IS NOT NULL
                   OR d.review_reason IS NOT NULL
                   OR shift.closed_at IS NOT NULL))
                 OR (d.status<>'pending' AND (
                   reviewer.id IS NULL OR reviewer.tenant_id<>b.tenant_id
                   OR d.reviewed_at IS NULL OR d.review_reason IS NULL
                   OR length(trim(d.review_reason))<12
                   OR d.reviewed_at<d.requested_at))
                 OR (d.status IN ('approved','rejected') AND (
                   reviewer.role NOT IN ('owner','manager')
                   OR d.reviewed_by=d.requested_by))
                 OR (d.status='cancelled' AND
                   d.reviewed_by<>d.requested_by)
                 OR (d.status='approved' AND (
                   d.reviewed_at<shift.opened_at
                   OR (shift.closed_at IS NOT NULL
                     AND d.reviewed_at>shift.closed_at)))
            """)
            check("cash_safe_negative_shift_expectation", """
              SELECT s.id,s.branch_id,s.opening_minor,
                COALESCE((SELECT SUM(l.cash_delta_minor)
                  FROM cash_shift_journal_links l
                  WHERE l.shift_id=s.id),0)
                +COALESCE((SELECT SUM(t.amount_minor)
                  FROM cash_drawer_transfers t
                  WHERE t.status='approved'
                    AND t.destination_shift_id=s.id),0)
                -COALESCE((SELECT SUM(t.amount_minor)
                  FROM cash_drawer_transfers t
                  WHERE t.status='approved'
                    AND t.source_shift_id=s.id),0)
                -COALESCE((SELECT SUM(d.amount_minor)
                  FROM cash_safe_drops d
                  WHERE d.status='approved'
                    AND d.source_shift_id=s.id),0)
                +s.opening_minor AS expected_minor
              FROM cash_shifts s
              WHERE s.drawer_id IS NOT NULL AND
                s.opening_minor+
                COALESCE((SELECT SUM(l.cash_delta_minor)
                  FROM cash_shift_journal_links l
                  WHERE l.shift_id=s.id),0)
                +COALESCE((SELECT SUM(t.amount_minor)
                  FROM cash_drawer_transfers t
                  WHERE t.status='approved'
                    AND t.destination_shift_id=s.id),0)
                -COALESCE((SELECT SUM(t.amount_minor)
                  FROM cash_drawer_transfers t
                  WHERE t.status='approved'
                    AND t.source_shift_id=s.id),0)
                -COALESCE((SELECT SUM(d.amount_minor)
                  FROM cash_safe_drops d
                  WHERE d.status='approved'
                    AND d.source_shift_id=s.id),0)<0
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
