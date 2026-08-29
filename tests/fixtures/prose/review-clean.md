`src/ingest/Scheduler.cs:212` releases the semaphore inside the `try`, so an
exception thrown by `ProcessAsync` leaks a permit. After 8 failures the pool is
empty and the worker hangs.

Move the release into a `finally`.
