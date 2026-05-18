from __future__ import annotations

import argparse
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import requests


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send many authenticated generation-job requests quickly."
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:5173")

    auth = parser.add_mutually_exclusive_group(required=True)
    auth.add_argument("--token", help="Existing Bearer token")
    auth.add_argument("--email", help="User email to log in with")
    parser.add_argument("--password", help="Password for --email login")

    parser.add_argument("--source-image-id", required=True)
    parser.add_argument(
        "--generation-mode",
        choices=["single", "multiview"],
        default="single",
    )
    parser.add_argument("--back-source-image-id")
    parser.add_argument("--left-source-image-id")
    parser.add_argument("--right-source-image-id")
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--concurrency", type=int, default=10)
    parser.add_argument("--name-prefix", default="quota-test")
    parser.add_argument("--category", default="stress-test")
    return parser.parse_args()


def _login(base_url: str, email: str, password: str | None) -> str:
    if not password:
        raise SystemExit("--password is required with --email")
    response = requests.post(
        f"{base_url.rstrip('/')}/auth/login",
        json={"email": email, "password": password},
        timeout=30,
    )
    response.raise_for_status()
    return response.json()["accessToken"]


def _job_payload(args: argparse.Namespace, index: int) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "sourceImageId": args.source_image_id,
        "generationMode": args.generation_mode,
        "name": f"{args.name_prefix}-{index}",
        "category": args.category,
    }
    if args.generation_mode == "multiview":
        missing = [
            name
            for name, value in (
                ("--back-source-image-id", args.back_source_image_id),
                ("--left-source-image-id", args.left_source_image_id),
                ("--right-source-image-id", args.right_source_image_id),
            )
            if not value
        ]
        if missing:
            raise SystemExit(f"Missing multiview arguments: {', '.join(missing)}")
        payload.update(
            {
                "backSourceImageId": args.back_source_image_id,
                "leftSourceImageId": args.left_source_image_id,
                "rightSourceImageId": args.right_source_image_id,
            }
        )
    return payload


def _post_job(
    base_url: str,
    token: str,
    payload: dict[str, Any],
    index: int,
) -> dict[str, Any]:
    response = requests.post(
        f"{base_url.rstrip('/')}/generation-jobs",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json=payload,
        timeout=30,
    )
    try:
        body: Any = response.json()
    except ValueError:
        body = response.text
    return {"index": index, "status_code": response.status_code, "body": body}


def main() -> None:
    args = _parse_args()
    token = args.token or _login(args.base_url, args.email, args.password)
    workers = max(1, min(args.concurrency, args.count))
    results: list[dict[str, Any]] = []

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [
            executor.submit(
                _post_job,
                args.base_url,
                token,
                _job_payload(args, index),
                index,
            )
            for index in range(1, args.count + 1)
        ]
        for future in as_completed(futures):
            results.append(future.result())

    results.sort(key=lambda item: item["index"])
    counts: dict[int, int] = {}
    for result in results:
        status_code = int(result["status_code"])
        counts[status_code] = counts.get(status_code, 0) + 1
        print(
            f"{result['index']:03d} HTTP {status_code}: "
            f"{json.dumps(result['body'], ensure_ascii=False)}"
        )

    print("Summary:", json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
