import os

from typesafe_sdk import Choice, Noul, RetryPolicy, Score, TypeSafeAuthenticationError, TypeSafeClient


with TypeSafeClient(
    api_key=os.environ["TYPESAFE_API_KEY"],
    base_url=os.environ["TYPESAFE_BASE_URL"],
    model="jev-latest",
    retry=RetryPolicy(max_retries=0),
    timeout=10,
) as client:
    models = client.models.list()
    assert models.models[0].name == "jev-synthetic"
    result = client.system_one(
        state={"task": "synthetic"},
        questions={
            "c": Choice(instructions="Choose", criteria={"a": "A", "b": "B"}),
            "n": {"type": "noul", "instructions": "Yes?", "custom_question": {"kept": True}},
            "s": Score(instructions="Rate", criteria=["low", "high"]),
            "optional": Noul(criteria={"true": "Yes"}),
            "null": {"type": "noul", "instructions": None, "criteria": None},
            "single": Score(criteria=["only"]),
        },
        extra_body={"extension": {"kept": True}},
    )

assert result.choices["c"].choice == "a"
assert result.nouls["n"].noul == 0.9
assert result.scores["s"].score == 0
assert result.nouls["optional"].noul == 0.9
assert result.nouls["null"].noul == 0.9
assert result.scores["single"].score == 0

with TypeSafeClient(
    api_key="synthetic-invalid-key",
    base_url=os.environ["TYPESAFE_BASE_URL"],
    retry=RetryPolicy(max_retries=0),
) as client:
    try:
        client.models.list()
    except TypeSafeAuthenticationError as error:
        assert error.status == 401
        assert error.headers["www-authenticate"] == "Bearer"
    else:
        raise AssertionError("An invalid source key must fail authentication")
print("python-sdk-ok")
