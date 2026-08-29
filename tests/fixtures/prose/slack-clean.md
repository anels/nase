ROBOTLOGS backfill for 2026-08-26 is still missing 4 partitions. The scheduler
drops a partition when it lands after the 02:00 UTC cutoff, so the three late
JP partitions never got picked up.

I reran the backfill at 09:20. It is green now.

• fix in `scripts/backfill.py:118` moves the cutoff check after the arrival poll
• the runbook at https://example.com/runbook still says 01:00, I will update it

cc @haowen, this touches the JP dashboard you looked at last week.
