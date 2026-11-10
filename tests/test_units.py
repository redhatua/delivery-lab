import pytest
from pydantic import ValidationError

from messenger.models import BroadcastRequest, fingerprint, parse_entry
from messenger.status import compute_status


@pytest.mark.parametrize(
    "acks,now,want",
    [
        ({}, 5, "pending"),
        ({}, 11, "timed_out"),
        ({"a": 4, "b": 9}, 9, "complete"),
        ({"a": 4, "b": 10}, 50, "complete"),  # exactly on the deadline is on time
        ({"a": 4, "b": 12}, 50, "complete_late"),
        ({"a": 4}, 50, "timed_out"),
    ],
)
def test_status(acks, now, want):
    assert compute_status(["a", "b"], acks, 10, now) == want


def test_fingerprint_depends_only_on_client_fields():
    a = BroadcastRequest(message="x", correlation_id="c")
    assert fingerprint(a) == fingerprint(BroadcastRequest(correlation_id="c", message="x"))
    assert fingerprint(a) != fingerprint(BroadcastRequest(message="x"))
    assert fingerprint(a) != fingerprint(BroadcastRequest(message="y", correlation_id="c"))


@pytest.mark.parametrize("payload", [{"message": ""}, {"message": "x" * 513}, {}])
def test_request_validation(payload):
    with pytest.raises(ValidationError):
        BroadcastRequest(**payload)


def test_parse_entry():
    good = {"event_id": "a" * 32, "origin": "m0", "targets": "m1,m2"}
    assert parse_entry(good).targets == ("m1", "m2")
    assert parse_entry({"event_id": "nope", "origin": "m0", "targets": "m1"}) is None
    assert parse_entry({"event_id": "a" * 32}) is None
