# Worker contract: commit after each completed step

After each discrete step (`plan`, `implement`, `test`, `review-fix`), create a git
commit in the worktree:

```bash
python "$WAVE_HOME/autonomy/worker_step_commit.py" "$PWD" "$WAVE_TICKET_ID" <step>
```

`WAVE_HOME`, `WAVE_TICKET_ID` and `WAVE_RUN_DIR` are set by the direct runtime at
spawn. The commit also records the step in the run's `status.json`, which is the
heartbeat `wave_status.py` and the tick read. Do not batch unrelated steps into one
commit. Push when the ticket prompt says to push.
