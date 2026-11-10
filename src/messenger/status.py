def compute_status(
    expected: list[str],
    ack_times_ms: dict[str, int],
    deadline_ms: int,
    now_ms: int,
) -> str:
    """pending | timed_out | complete | complete_late.

    Timing out is only a display state; a late ACK still completes the event.
    """
    missing = [m for m in expected if m not in ack_times_ms]
    if missing:
        return "timed_out" if now_ms > deadline_ms else "pending"
    last = max(ack_times_ms[m] for m in expected)
    return "complete" if last <= deadline_ms else "complete_late"
