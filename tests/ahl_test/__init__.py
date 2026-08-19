"""Shared helpers for the autohomelab validity acceptance suite.

Nothing here asserts anything — it only locates the implementation under test and normalizes
its return shapes, so that a missing implementation SKIPS (with a message naming exactly what
is missing) instead of erroring.
"""
