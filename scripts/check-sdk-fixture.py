import os

from typesafe_sdk import Choice, RetryPolicy, Score, TypeSafeClient


with TypeSafeClient(
    api_key=os.environ["FALCON_TEST_TOKEN"],
    base_url=os.environ["FALCON_TEST_BASE_URL"],
    model="jev-latest",
    retry=RetryPolicy(max_retries=0),
    timeout=10,
) as client:
    result = client.system_one(
        state={"task": "synthetic"},
        questions={
            "c": Choice(instructions="Choose", criteria={"a": "A", "b": "B"}),
            "n": {"type": "noul", "instructions": "Yes?", "custom_question": {"kept": True}},
            "s": Score(instructions="Rate", criteria=["low", "high"]),
        },
        extra_body={"extension": {"kept": True}},
    )

assert result.choices["c"].choice == "a"
assert result.nouls["n"].noul == 0.9
assert result.scores["s"].score == 0
print("python-sdk-ok")
