# -*- coding: utf-8 -*-
"""
WorkBuddy 签到日历 - 记录表补记工具

用途：把「当天确实签到成功、但记录表里没有 credit 值」的缺失记录补进
      checkin-records.csv（方案B），并重排序号。

背景：单次积分来自接口响应 data.credit；「本周/累计已领取积分」是本地对
      CSV 中 credit=N 的累加。若某天是手动在客户端签到、或接口返回
      code=10001「已签到」，该天不会产生 credit 值，导致汇总偏小。

幂等：
  - 默认按「执行时间」判重（完全相同的时刻不重复写入）。
  - 加 --unique-date 后，只要该日期已有任意记录就跳过（适合按天补记）。

用法示例：
  python add_record.py --csv signin-records/checkin-records.csv \
      --time "2026-09-14 09:27:14" --result "签到成功（补记）" \
      --credit 100 --streak 8 --unique-date \
      --note "接口返回「今日已签到」，按每日基础分记"
"""

import argparse
import csv
import io
import os
import sys

HEADERS = ["序号", "执行时间", "执行结果", "执行结论", "令牌状态", "守卫脚本判定", "积分/连签", "备注"]

DEFAULT_CONCLUSION = "本次成功领取积分"
DEFAULT_TOKEN = "有效"
DEFAULT_GUARD = "RUN - marker written（当日完成，后续跳过）"


def load_rows(path):
    if not os.path.exists(path):
        return []
    with io.open(path, "r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def save_rows(path, rows):
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with io.open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writerow(HEADERS)
        for i, r in enumerate(rows, start=1):
            w.writerow([
                str(i),
                r.get("执行时间", ""),
                r.get("执行结果", ""),
                r.get("执行结论", ""),
                r.get("令牌状态", ""),
                r.get("守卫脚本判定", ""),
                r.get("积分/连签", ""),
                r.get("备注", ""),
            ])


def main():
    ap = argparse.ArgumentParser(description="Backfill a manual check-in record into the CSV.")
    ap.add_argument("--csv", required=True, help="checkin-records.csv 路径")
    ap.add_argument("--time", required=True, help='执行时间，格式 "YYYY-MM-DD HH:MM:SS"')
    ap.add_argument("--result", default="签到成功", help="执行结果（默认 签到成功）")
    ap.add_argument("--conclusion", default="", help="执行结论（默认按 result 推断）")
    ap.add_argument("--token", default=DEFAULT_TOKEN, help="令牌状态")
    ap.add_argument("--guard", default=DEFAULT_GUARD, help="守卫脚本判定")
    ap.add_argument("--credit", type=int, default=None, help="本次领取积分（接口 data.credit）")
    ap.add_argument("--streak", type=int, default=None, help="连续签到天数（接口 data.streak_days）")
    ap.add_argument("--note", default="", help="备注")
    ap.add_argument("--unique-date", action="store_true", help="该日期已有任意记录则跳过")
    ap.add_argument("--dry-run", action="store_true", help="只打印将要写入的内容，不落盘")
    a = ap.parse_args()

    # --- 参数校验 ---
    t = a.time.strip()
    if len(t) != 19 or t[4] != "-" or t[7] != "-" or t[10] != " " or t[13] != ":" or t[16] != ":":
        print("BAD_TIME_FORMAT expected 'YYYY-MM-DD HH:MM:SS'")
        return 2
    day = t[:10]

    rows = load_rows(a.csv)

    # --- 幂等判定 ---
    if any((r.get("执行时间") or "").strip() == t for r in rows):
        print("SKIP duplicate-time total=%d" % len(rows))
        return 0
    if a.unique_date and any((r.get("执行时间") or "")[:10] == day for r in rows):
        print("SKIP date-already-present total=%d" % len(rows))
        return 0

    # --- 组装积分/连签 ---
    credit_field = "-"
    if a.credit is not None:
        credit_field = "credit=%d" % a.credit
        if a.streak is not None:
            credit_field += " streak=%d" % a.streak

    conclusion = a.conclusion or DEFAULT_CONCLUSION
    if not a.conclusion:
        if "签到成功" in a.result:
            conclusion = DEFAULT_CONCLUSION
        elif "失败" in a.result:
            conclusion = "签到未成功，后续运行将重试"
        else:
            conclusion = "当日已完成，未重复领取"

    new_row = {
        "执行时间": t,
        "执行结果": a.result,
        "执行结论": conclusion,
        "令牌状态": a.token,
        "守卫脚本判定": a.guard,
        "积分/连签": credit_field,
        "备注": a.note,
    }

    # --- 按执行时间升序插入（定宽格式，字典序 == 时间序）---
    merged = rows + [new_row]
    merged.sort(key=lambda r: (r.get("执行时间") or ""))

    if a.dry_run:
        print("DRY_RUN would-insert time=%s credit=%s total-after=%d" % (t, credit_field, len(merged)))
        return 0

    save_rows(a.csv, merged)
    print("ADDED time=%s credit=%s total=%d" % (t, credit_field, len(merged)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
