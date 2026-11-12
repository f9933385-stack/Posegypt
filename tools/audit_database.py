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
