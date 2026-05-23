"""Duration parsing and ISO-8601 timestamp utilities."""

import re
from datetime import datetime, timedelta, timezone


def now_utc() -> datetime:
    return datetime.now(tz=timezone.utc)


def isoformat(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> datetime:
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


_DURATION_RE = re.compile(r"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$")


def parse_duration(s: str) -> timedelta:
    m = _DURATION_RE.match(s or "")
    if not m or not any(m.groups()):
        raise ValueError(f"Cannot parse duration: {s!r} — expected e.g. '4h', '30m', '1h30m'")
    h, mi, sec = (int(x or 0) for x in m.groups())
    return timedelta(hours=h, minutes=mi, seconds=sec)


def compute_expiry(ttl_str: str, started_at: datetime) -> datetime:
    return started_at + parse_duration(ttl_str)
