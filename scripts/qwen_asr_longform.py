#!/usr/bin/env python3

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Sequence


@dataclass(frozen=True)
class Interval:
    start: float
    end: float


def parse_silence_events(log: str) -> list[Interval]:
    starts = [
        float(value)
        for value in re.findall(r"silence_start:\s*([0-9]+(?:\.[0-9]+)?)", log)
    ]
    ends = [
        float(value)
        for value in re.findall(r"silence_end:\s*([0-9]+(?:\.[0-9]+)?)", log)
    ]
    return [
        Interval(start, end)
        for start, end in zip(starts, ends)
        if end >= start
    ]


def plan_chunks(
    duration: float,
    silences: Sequence[Interval],
    target: float = 120.0,
    maximum: float = 180.0,
    padding: float = 1.5,
) -> list[Interval]:
    raw_intervals: list[Interval] = []
    start = 0.0

    while duration - start > target:
        desired = min(start + target, duration)
        latest = min(start + maximum, duration)
        candidates = [
            (silence.start + silence.end) / 2
            for silence in silences
            if start + 30.0
            <= (silence.start + silence.end) / 2
            <= latest
        ]
        cut = (
            min(candidates, key=lambda value: abs(value - desired))
            if candidates
            else desired
        )
        raw_intervals.append(Interval(start, cut))
        start = cut

    raw_intervals.append(Interval(start, duration))
    return [
        Interval(
            max(0.0, interval.start - padding),
            min(duration, interval.end + padding),
        )
        for interval in raw_intervals
    ]


def validate_transcript(text: object) -> tuple[bool, str]:
    if not isinstance(text, str) or not text.strip():
        return False, "empty-text"

    compact = re.sub(r"\s+", "", text)
    if re.search(r"(.)\1{19,}$", compact):
        return False, "repeated-character-tail"
    if re.search(r"(.{2,8})\1{9,}$", compact):
        return False, "repeated-pattern-tail"
    return True, "ok"


def merge_transcripts(
    texts: Sequence[str],
    minimum_overlap: int = 8,
) -> str:
    accepted: list[str] = []
    for text in (value.strip() for value in texts if value.strip()):
        if accepted:
            limit = min(len(accepted[-1]), len(text))
            overlap = next(
                (
                    size
                    for size in range(limit, minimum_overlap - 1, -1)
                    if accepted[-1].endswith(text[:size])
                ),
                0,
            )
            text = text[overlap:].lstrip()
        if text:
            accepted.append(text)
    return "\n".join(accepted)
