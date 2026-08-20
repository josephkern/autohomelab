#!/usr/bin/env python3
"""power.py — can this comparison resolve the difference I care about, and if not, what n would?

A decision-time calculator for the two gates that feed keep/discard decisions:

  Gate 2 (quality) — binomial. `accuracy` answers it analytically, for the UNPAIRED comparison
    the harness performs today and for the PAIRED (McNemar) comparison it could perform if
    lm-eval logged per-sample outcomes. It also knows that `--limit L` is applied PER LEAF
    SUBTASK, so `mmlu --limit 100` is n=5,700 and not n=100 -- the arithmetic the LIMIT=100
    follow-up turns on.

  Gate 3 (throughput) — no assumed distribution. `throughput` reads the repo's OWN replicate
    brackets out of results/*/*/*/results.tsv and uses the measured relative spread. The loop's
    primitive is a MEDIAN of N=3, not a mean, so the estimator's sampling SD is modelled as the
    SD of a sample median (0.6698 sigma at n=3), not sigma/sqrt(3).

Subcommands
  accuracy    MDE / required-n for an accuracy comparison (paired and unpaired)
  throughput  MDE / false-keep rate / required reps for a tok/s comparison
  keep-rule   evaluate the KEEP rule EXACTLY as AGENTS.md/program.md state it
  variance    dump the empirical variance tables this tool plans against
  seed        measure what AHL_SEED=42 pairing buys (needs the gitignored raw bundles)
  mcnemar     exact paired test on two discordant counts, or on two lm-eval sample files
  selftest    numeric self-checks (see scripts/power_selftest.sh)

Everything is stdlib. The special functions (regularized incomplete beta, Student-t quantile,
exact binomial tail, SD of the sample median) are implemented here and checked in `selftest`
against hand-computable values, published table values, and seeded Monte Carlo.

Sign conventions
  * accuracy deltas are PERCENTAGE POINTS unless --relative is given. AGENTS.md's "within ~1%"
    is ambiguous between the two; at mmlu~82 they differ by 18% (1.00 pt vs 0.82 pt).
  * throughput deltas are RELATIVE PERCENT, matching the ">3%" KEEP rule.
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import math
import os
import random
import re
import statistics
import sys
from collections import defaultdict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ─────────────────────────────────────────────────────────────────────────────
# Measured constants (provenance: research/review/POWER-analysis.md, 15 campaigns on gb10).
# These are used ONLY for the wall-clock cost line and for effective-n fallbacks; every
# statistical result is computed, never table-looked-up.
# ─────────────────────────────────────────────────────────────────────────────

# lm-eval `--limit L` is applied PER LEAF SUBTASK. `mmlu` has 57 leaves, `mmlu_pro` has 14,
# so LIMIT=100 is n=5700 and n=1400 respectively -- not n=100. This is the single most
# load-bearing fact in the whole LIMIT=100 discussion.
TASK_LEAVES = {"mmlu": 57, "mmlu_pro": 14, "gsm8k": 1, "humaneval": 1, "mbpp": 1,
               "aime24": 1, "aime25": 1}
TASK_FULL_N = {"mmlu": 14042, "mmlu_pro": 12032, "gsm8k": 1319, "humaneval": 164,
               "mbpp": 500, "aime24": 30, "aime25": 30}
# median seconds per effective sample on this node, across the retained lm-eval bundles.
# Spread across models is ~2-3x; treat as an order-of-magnitude planning number.
TASK_SECONDS_PER_SAMPLE = {"mmlu": 0.178, "mmlu_pro": 2.02, "gsm8k": 2.22,
                           "humaneval": 0.57, "mbpp": 0.57, "aime24": 124.8, "aime25": 124.8}
# typical headline accuracy, used only as a default --p when the caller gives none
TASK_TYPICAL_P = {"mmlu": 0.82, "mmlu_pro": 0.70, "gsm8k": 0.92, "humaneval": 0.45,
                  "mbpp": 0.75, "aime24": 0.60, "aime25": 0.60}

LEVELS = ["c1", "c4", "c8", "c16", "c32"]

# ─────────────────────────────────────────────────────────────────────────────
# Special functions
# ─────────────────────────────────────────────────────────────────────────────

_ND = statistics.NormalDist()


def norm_cdf(x: float) -> float:
    return _ND.cdf(x)


def norm_ppf(p: float) -> float:
    if not 0.0 < p < 1.0:
        raise ValueError("norm_ppf needs 0<p<1, got %r" % (p,))
    return _ND.inv_cdf(p)


def _log_beta(a: float, b: float) -> float:
    return math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)


def _betacf(x: float, a: float, b: float, itmax: int = 300, eps: float = 3e-16) -> float:
    """Continued fraction for the incomplete beta (Lentz's method, Numerical Recipes 6.4)."""
    tiny = 1e-300
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < tiny:
        d = tiny
    d = 1.0 / d
    h = d
    for m in range(1, itmax + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < tiny:
            d = tiny
        c = 1.0 + aa / c
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < tiny:
            d = tiny
        c = 1.0 + aa / c
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        de = d * c
        h *= de
        if abs(de - 1.0) < eps:
            break
    return h


def betainc(x: float, a: float, b: float) -> float:
    """Regularized incomplete beta I_x(a,b)."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    front = math.exp(a * math.log(x) + b * math.log1p(-x) - _log_beta(a, b))
    if x < (a + 1.0) / (a + b + 2.0):
        return front * _betacf(x, a, b) / a
    return 1.0 - math.exp(b * math.log1p(-x) + a * math.log(x) - _log_beta(b, a)) * \
        _betacf(1.0 - x, b, a) / b


def betainc_inv(p: float, a: float, b: float, tol: float = 1e-12) -> float:
    """Inverse of betainc in x, by bisection (monotone in x, so bisection is safe)."""
    if p <= 0.0:
        return 0.0
    if p >= 1.0:
        return 1.0
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if betainc(mid, a, b) < p:
            lo = mid
        else:
            hi = mid
        if hi - lo < tol:
            break
    return 0.5 * (lo + hi)


def t_cdf(t: float, df: float) -> float:
    """Student-t CDF via the incomplete beta."""
    x = df / (df + t * t)
    tail = 0.5 * betainc(x, df / 2.0, 0.5)
    return 1.0 - tail if t > 0 else tail


def t_ppf(p: float, df: float) -> float:
    """Student-t quantile via the inverse incomplete beta."""
    if not 0.0 < p < 1.0:
        raise ValueError("t_ppf needs 0<p<1")
    if p == 0.5:
        return 0.0
    q = 2.0 * min(p, 1.0 - p)
    x = betainc_inv(q, df / 2.0, 0.5)
    t = math.sqrt(df * (1.0 - x) / x)
    return t if p > 0.5 else -t


def binom_cdf(k: int, n: int, p: float) -> float:
    """P(X <= k) for X~Bin(n,p). Exact sum for small n, incomplete beta otherwise."""
    if k < 0:
        return 0.0
    if k >= n:
        return 1.0
    if n <= 1000:
        return sum(math.comb(n, i) * p ** i * (1.0 - p) ** (n - i) for i in range(k + 1))
    return 1.0 - betainc(p, k + 1, n - k)


def binom_test_two_sided(k: int, n: int, p: float = 0.5) -> float:
    """Exact two-sided binomial test. For p=0.5 this is the doubled tail (the standard
    exact McNemar p-value)."""
    if n == 0:
        return 1.0
    if p == 0.5:
        lo = min(k, n - k)
        return min(1.0, 2.0 * binom_cdf(lo, n, 0.5))
    # general case: sum of all outcomes no more likely than the observed one
    obs = math.comb(n, k) * p ** k * (1 - p) ** (n - k)
    tot = 0.0
    for i in range(n + 1):
        pr = math.comb(n, i) * p ** i * (1 - p) ** (n - i)
        if pr <= obs * (1 + 1e-9):
            tot += pr
    return min(1.0, tot)


def clopper_pearson(k: int, n: int, alpha: float = 0.05):
    """Exact (Clopper-Pearson) binomial confidence interval."""
    lo = 0.0 if k == 0 else betainc_inv(alpha / 2.0, k, n - k + 1)
    hi = 1.0 if k == n else betainc_inv(1.0 - alpha / 2.0, k + 1, n - k)
    return lo, hi


# ─────────────────────────────────────────────────────────────────────────────
# SD of the sample median — the loop's estimator is a median of N, not a mean
# ─────────────────────────────────────────────────────────────────────────────

_MEDIAN_SD_CACHE: dict = {}
_GRID_LO, _GRID_HI = -9.0, 9.0
_ASYMPTOTIC_FROM = 51   # above this, pi/(2n) is within ~1% and the quadrature is not worth it


def _grid(steps: int):
    """Shared (x, F(x), phi(x)) grid for the order-statistic quadratures."""
    h = (_GRID_HI - _GRID_LO) / steps
    xs = [_GRID_LO + i * h for i in range(steps + 1)]
    Fs = [norm_cdf(x) for x in xs]
    ps = [math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi) for x in xs]
    return h, xs, Fs, ps


def _simpson_w(i: int, steps: int) -> float:
    return 1.0 if i in (0, steps) else (4.0 if i % 2 else 2.0)


def _median_var_odd(n: int, steps: int = 4000) -> float:
    """Var of the median of n iid N(0,1), n odd, by Simpson integration of the order-statistic
    density  f_M(x) = n!/(m!m!) F(x)^m (1-F(x))^m f(x),  m=(n-1)/2."""
    m = (n - 1) // 2
    logc = math.lgamma(n + 1) - 2.0 * math.lgamma(m + 1)
    h, xs, Fs, ps = _grid(steps)
    total = 0.0
    for i, x in enumerate(xs):
        F = Fs[i]
        if F <= 0.0 or F >= 1.0:
            continue
        d = math.exp(logc + m * math.log(F) + m * math.log1p(-F)) * ps[i]
        total += _simpson_w(i, steps) * x * x * d
    return total * h / 3.0


def _median_var_even(n: int, steps: int = 20000, check: bool = False):
    """Var of the median of n iid N(0,1), n even: M = (X_(m) + X_(m+1))/2 with n=2m.

    The two are CONSECUTIVE order statistics, so their joint density loses the middle term:
        f(u,v) = n!/((m-1)!(m-1)!) F(u)^(m-1) (1-F(v))^(m-1) f(u) f(v),  u < v
    The domain is the triangle u < v, so a product Simpson rule over a square grid is simply
    wrong there (it was: it ran 2-5% low, growing with n). Instead the inner integral is done
    as a CUMULATIVE integral and expanded analytically:

        E[M^2] = C * INT R(v) * (1/4)[ I2(v) + 2v*I1(v) + v^2*I0(v) ] dv
        Ik(v)  = INT_{-inf}^{v} u^k L(u) du,     L(u) = F(u)^(m-1) f(u)
                                                 R(v) = (1-F(v))^(m-1) f(v)

    E[M] = 0 by symmetry, so E[M^2] is the variance. `check` also returns the total mass,
    which must integrate to 1 -- that is the test that the constant C and the quadrature agree.

    The even and odd sequences of n*Var(median) are genuinely different (1.19, 1.29, 1.35 ...
    vs 1.35, 1.43, 1.47 ...), both converging to pi/2, so interpolating across parity would be
    wrong -- hence the separate quadrature."""
    m = n // 2
    c = math.exp(math.lgamma(n + 1) - 2.0 * math.lgamma(m))
    h, xs, Fs, ps = _grid(steps)
    L = [0.0 if Fs[i] <= 0.0 else math.exp((m - 1) * math.log(Fs[i])) * ps[i]
         for i in range(len(xs))]
    R = [0.0 if Fs[i] >= 1.0 else math.exp((m - 1) * math.log1p(-Fs[i])) * ps[i]
         for i in range(len(xs))]
    # cumulative trapezoid for I0, I1, I2 (h ~ 9e-4 -> relative error ~1e-7)
    I0 = [0.0] * len(xs)
    I1 = [0.0] * len(xs)
    I2 = [0.0] * len(xs)
    for i in range(1, len(xs)):
        u0, u1 = xs[i - 1], xs[i]
        a, b = L[i - 1], L[i]
        I0[i] = I0[i - 1] + 0.5 * h * (a + b)
        I1[i] = I1[i - 1] + 0.5 * h * (u0 * a + u1 * b)
        I2[i] = I2[i - 1] + 0.5 * h * (u0 * u0 * a + u1 * u1 * b)
    tot = 0.0
    mass = 0.0
    for j, v in enumerate(xs):
        rj = R[j]
        if rj == 0.0:
            continue
        w = _simpson_w(j, steps)
        tot += w * rj * 0.25 * (I2[j] + 2.0 * v * I1[j] + v * v * I0[j])
        mass += w * rj * I0[j]
    var = c * tot * h / 3.0
    if check:
        return var, c * mass * h / 3.0
    return var


def median_sd_factor(n: int) -> float:
    """SD of the sample median of n iid N(0,1), in units of sigma.

    n=1 -> 1; n=2 -> 1/sqrt(2) (the median of two IS their mean); odd/even quadrature up to
    n=%d; above that the asymptotic sqrt(pi/(2n)), which is within ~1%% there and falling.""" \
        % _ASYMPTOTIC_FROM
    if n < 1:
        raise ValueError("n>=1")
    if n == 1:
        return 1.0
    if n == 2:
        return 1.0 / math.sqrt(2.0)
    v = _MEDIAN_SD_CACHE.get(n)
    if v is not None:
        return v
    if n > _ASYMPTOTIC_FROM:
        var = math.pi / (2.0 * n)
    else:
        var = _median_var_odd(n) if n % 2 else _median_var_even(n)
    v = math.sqrt(var)
    _MEDIAN_SD_CACHE[n] = v
    return v


def estimator_sd_factor(n: int, estimator: str = "median") -> float:
    if estimator == "mean":
        return 1.0 / math.sqrt(n)
    if estimator == "median":
        return median_sd_factor(n)
    raise ValueError("estimator must be mean|median")


# ─────────────────────────────────────────────────────────────────────────────
# Accuracy power — unpaired two-proportion and paired McNemar
# ─────────────────────────────────────────────────────────────────────────────

def n_two_prop(p1: float, p2: float, alpha: float = 0.05, power: float = 0.80) -> float:
    """Per-arm n for a two-sided two-proportion z-test (pooled-variance form; the version that
    reproduces Fleiss's uncorrected table, e.g. .25 vs .50 -> 58/arm at alpha .05 power .80)."""
    d = abs(p1 - p2)
    if d <= 0:
        return float("inf")
    pb = 0.5 * (p1 + p2)
    za = norm_ppf(1.0 - alpha / 2.0)
    zb = norm_ppf(power)
    num = za * math.sqrt(2.0 * pb * (1.0 - pb)) + zb * math.sqrt(p1 * (1 - p1) + p2 * (1 - p2))
    return num * num / (d * d)


def power_two_prop(n: float, p1: float, p2: float, alpha: float = 0.05) -> float:
    d = abs(p1 - p2)
    if n <= 0:
        return 0.0
    pb = 0.5 * (p1 + p2)
    za = norm_ppf(1.0 - alpha / 2.0)
    num = d * math.sqrt(n) - za * math.sqrt(2.0 * pb * (1.0 - pb))
    return norm_cdf(num / math.sqrt(p1 * (1 - p1) + p2 * (1 - p2)))


def mde_two_prop(n: float, p: float, alpha: float = 0.05, power: float = 0.80) -> float:
    """Smallest DROP from p that is detectable at the given n/alpha/power.

    The search runs over the whole admissible range (0, p) -- a 92%-accurate model can fall all
    the way to 0, so bounding the search at min(p,1-p) would report 'unreachable' for exactly
    the high-accuracy tasks the repo cares about."""
    lo, hi = 1e-9, p * 0.999999
    if power_two_prop(n, p, max(0.0, p - hi), alpha) < power:
        return float("nan")
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if power_two_prop(n, p, p - mid, alpha) < power:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def n_mcnemar(psi: float, delta: float, alpha: float = 0.05, power: float = 0.80) -> float:
    """Number of PAIRS for a two-sided McNemar test (Connor 1987).
    psi = discordance rate p01+p10, delta = |p01-p10| = the accuracy difference in proportion."""
    if delta <= 0 or psi <= 0:
        return float("inf")
    # |p01-p10| <= p01+p10 by construction: a pair of configs cannot differ by more than they
    # discord. A caller asking for delta > psi has specified an impossible world; the honest
    # repair is to raise psi to delta, not to answer the impossible question.
    if psi < delta:
        psi = delta
    za = norm_ppf(1.0 - alpha / 2.0)
    zb = norm_ppf(power)
    num = za * math.sqrt(psi) + zb * math.sqrt(psi - delta * delta)
    return num * num / (delta * delta)


def power_mcnemar(n: float, psi: float, delta: float, alpha: float = 0.05) -> float:
    if delta <= 0 or psi <= 0 or n <= 0:
        return 0.0
    za = norm_ppf(1.0 - alpha / 2.0)
    var = max(psi - delta * delta, 1e-15)
    return norm_cdf((delta * math.sqrt(n) - za * math.sqrt(psi)) / math.sqrt(var))


def mde_mcnemar(n: float, psi: float, alpha: float = 0.05, power: float = 0.80) -> float:
    """Smallest |p01-p10| detectable at n pairs and discordance psi. Capped at psi itself:
    two configs cannot differ by more than they discord."""
    lo, hi = 1e-9, psi * 0.999999
    if power_mcnemar(n, psi, hi, alpha) < power:
        return float("nan")
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if power_mcnemar(n, psi, mid, alpha) < power:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


# ─────────────────────────────────────────────────────────────────────────────
# Throughput — decision-rule error rates for "median beats reference by >T"
# ─────────────────────────────────────────────────────────────────────────────

def diff_sd(cv: float, n_cand: int, n_ref: int, estimator: str = "median",
            paired_ref: bool = False) -> float:
    """SD of log(median_cand / median_ref) under relative noise of size cv.

    For cv <~ 10% the log- and linear-relative scales agree to better than 1%, and the log
    scale keeps the ratio symmetric, which is what a '>3%' rule is really about."""
    s = math.log1p(cv) if cv < 0.5 else math.log(1.0 + cv)
    a = estimator_sd_factor(n_cand, estimator) * s
    if paired_ref:
        return a  # reference treated as known (e.g. an enormous historical set); optimistic
    b = estimator_sd_factor(n_ref, estimator) * s
    return math.hypot(a, b)


def false_keep_prob(threshold: float, cv: float, n_cand: int = 3, n_ref: int = 3,
                    estimator: str = "median") -> float:
    """P(rule fires) when the two configs are actually identical. threshold is RELATIVE
    (0.03 for the repo's >3%)."""
    sd = diff_sd(cv, n_cand, n_ref, estimator)
    return 1.0 - norm_cdf(math.log1p(threshold) / sd)


def keep_power(true_effect: float, threshold: float, cv: float, n_cand: int = 3,
               n_ref: int = 3, estimator: str = "median") -> float:
    """P(rule fires) when the candidate is genuinely `true_effect` relative faster."""
    sd = diff_sd(cv, n_cand, n_ref, estimator)
    return norm_cdf((math.log1p(true_effect) - math.log1p(threshold)) / sd)


def mde_throughput(cv: float, n_cand: int = 3, n_ref: int = 3, alpha: float = 0.05,
                   power: float = 0.80, estimator: str = "median") -> float:
    """Smallest TRUE relative effect a two-sided test at this n would call significant."""
    sd = diff_sd(cv, n_cand, n_ref, estimator)
    return math.expm1((norm_ppf(1.0 - alpha / 2.0) + norm_ppf(power)) * sd)


def reps_for_threshold(threshold: float, cv: float, max_false_keep: float = 0.05,
                       estimator: str = "median", nmax: int = 999) -> int:
    """Smallest N (both arms) at which the '>threshold' rule's false-keep rate is <= target."""
    for n in range(2, nmax + 1):
        if false_keep_prob(threshold, cv, n, n, estimator) <= max_false_keep:
            return n
    return -1


def reps_for_mde(cv: float, delta: float, alpha: float = 0.05, power: float = 0.80,
                 estimator: str = "median", nmax: int = 999) -> int:
    for n in range(2, nmax + 1):
        if mde_throughput(cv, n, n, alpha, power, estimator) <= delta:
            return n
    return -1


# ─────────────────────────────────────────────────────────────────────────────
# Empirical data layer — the repo's own replicate spread
# ─────────────────────────────────────────────────────────────────────────────

def _rows(pattern: str, root: str):
    for f in sorted(glob.glob(os.path.join(root, pattern))):
        with open(f, newline="") as fh:
            for r in csv.DictReader(fh, delimiter="\t"):
                r["_file"] = f
                yield r


def _exp_id(row) -> str:
    m = re.search(r"exp=(\S+)", row.get("notes") or "")
    return m.group(1) if m else "solo:" + (row.get("run_id") or "")


def _row_ok_at(row, level: str) -> bool:
    """Contract §3: gate on the level being cited. void/crash/suspect rows are not data."""
    if (row.get("status") or "") in ("void", "crash", "suspect"):
        return False
    for tok in (row.get("validity") or "").split("+"):
        if tok.endswith("@" + level):
            return False
    return True


def _tps(row, level: str):
    try:
        v = float(row.get("tps_" + level, "na"))
    except (TypeError, ValueError):
        return None
    return v if v > 0 else None


def throughput_brackets(root: str = REPO_ROOT, level: str = "c16", model: str = None,
                        shape: str = None, scope: str = "experiment"):
    """Replicate brackets = repeated benches of ONE config that should have produced the
    same number.

      scope=experiment  rows sharing an `exp=` tag (the N=3 the loop medians over: one serve
                        session, one config, minutes apart). This is the variance the KEEP
                        rule is actually applied to.
      scope=session     same config + shape on the same calendar day, regardless of exp tag.
      scope=cross       session medians of the same config on DIFFERENT days.
    """
    rows = [r for r in _rows("results/*/*/*/results.tsv", root)]
    if model:
        rows = [r for r in rows if model.lower() in (r.get("model") or "").lower()]
    if shape:
        rows = [r for r in rows if shape in (r.get("shape") or "")]
    out = []
    if scope == "cross":
        g = defaultdict(lambda: defaultdict(list))
        for r in rows:
            if _row_ok_at(r, level) and _tps(r, level):
                g[(r["model"], r["config_hash"], r["shape"])][r["run_id"][:8]].append(_tps(r, level))
        for key, byday in g.items():
            vals = [statistics.median(v) for v in byday.values() if v]
            if len(vals) >= 2:
                out.append((statistics.stdev(vals) / statistics.mean(vals), len(vals), key,
                            sorted(vals)))
        return out
    keyfn = (lambda r: (r["model"], r["config_hash"], r["shape"], _exp_id(r))) \
        if scope == "experiment" else \
        (lambda r: (r["model"], r["config_hash"], r["shape"], r["run_id"][:8]))
    g = defaultdict(list)
    for r in rows:
        if _row_ok_at(r, level) and _tps(r, level):
            g[keyfn(r)].append(_tps(r, level))
    for key, vals in g.items():
        if len(vals) >= 2:
            out.append((statistics.stdev(vals) / statistics.mean(vals), len(vals), key,
                        sorted(vals)))
    return out


def pooled_cv(brackets):
    """Pooled relative SD over brackets: sqrt( sum df_i*cv_i^2 / sum df_i ).

    Prefer this to the median of per-bracket CVs for planning: a CV from k=3 is itself a
    noisy chi-square estimate (its median is ~0.65x its true value at k=3), so the median of
    CVs is badly downward-biased, while the pooled figure is a proper variance estimate."""
    num = sum((k - 1) * cv * cv for cv, k, _, _ in brackets)
    den = sum(k - 1 for cv, k, _, _ in brackets)
    return math.sqrt(num / den) if den else float("nan")


def bracket_summary(brackets):
    if not brackets:
        return None
    cvs = sorted(cv for cv, _, _, _ in brackets)

    def q(p):
        return cvs[min(len(cvs) - 1, int(p * (len(cvs) - 1)))]
    return dict(brackets=len(brackets), df=sum(k - 1 for _, k, _, _ in brackets),
                pooled_cv=pooled_cv(brackets), median_cv=statistics.median(cvs),
                p75_cv=q(0.75), p90_cv=q(0.90), max_cv=max(cvs),
                typical_k=statistics.median([k for _, k, _, _ in brackets]))


def accuracy_effective_n(task: str, limit, root: str = REPO_ROOT):
    """Effective sample count for `task` at `--limit L`.

    lm-eval applies --limit per LEAF SUBTASK, so mmlu@100 is n=5700 and mmlu_pro@100 is
    n=1400. Preference order: (1) what the repo's own accuracy.tsv recorded for this exact
    (task, limit); (2) leaves x limit, capped at the task's full size."""
    want = "full" if limit in (None, "full", 0) else str(int(limit))
    seen = set()
    for r in _rows("results/*/*/*/accuracy.tsv", root):
        if (r.get("limit") or "") != want:
            continue
        for part in (r.get("samples") or "").split(";"):
            if "=" not in part:
                continue
            t, eff = part.split("=", 1)
            if t != task or "/" not in eff:
                continue
            try:
                seen.add(int(eff.split("/")[0]))
            except ValueError:
                pass
    if seen:
        return max(seen), "measured (accuracy.tsv)"
    full = TASK_FULL_N.get(task)
    if want == "full":
        return (full, "table") if full else (None, "unknown")
    leaves = TASK_LEAVES.get(task)
    if leaves is None:
        return None, "unknown"
    n = leaves * int(want)
    if full:
        n = min(n, full)
    return n, "leaves x limit (table)"


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def _fmt_n(x):
    if x is None or (isinstance(x, float) and (math.isinf(x) or math.isnan(x))):
        return "n/a"
    return "{:,}".format(int(math.ceil(x)))


def _emit(obj, as_json, lines):
    if as_json:
        print(json.dumps(obj, indent=2, sort_keys=True))
    else:
        print("\n".join(lines))


def cmd_accuracy(a):
    task = a.task
    if a.n:
        n, prov = a.n, "given on the command line"
    else:
        n, prov = accuracy_effective_n(task, a.limit, a.root)
    if not n:
        print("cannot determine n for task=%s limit=%s; pass --n" % (task, a.limit),
              file=sys.stderr)
        return 2
    p = a.p if a.p is not None else TASK_TYPICAL_P.get(task, 0.85)
    delta = a.delta / 100.0 * (p if a.relative else 1.0)
    unpaired_mde = mde_two_prop(n, p, a.alpha, a.power)
    unpaired_n = n_two_prop(p, p - delta, a.alpha, a.power)
    paired_mde = mde_mcnemar(n, a.discordance, a.alpha, a.power)
    paired_n = n_mcnemar(a.discordance, delta, a.alpha, a.power)
    se = math.sqrt(p * (1 - p) / n)
    k = int(round(p * n))
    lo, hi = clopper_pearson(k, n, a.alpha)
    secs = TASK_SECONDS_PER_SAMPLE.get(task)
    resolves_unpaired = not math.isnan(unpaired_mde) and unpaired_mde <= delta
    resolves_paired = not math.isnan(paired_mde) and paired_mde <= delta

    obj = dict(task=task, limit=a.limit, n=n, n_provenance=prov, p=p, alpha=a.alpha,
               power=a.power, delta_points=delta * 100,
               se_points=se * 100, ci95_points=[lo * 100, hi * 100],
               unpaired=dict(mde_points=unpaired_mde * 100, n_required=unpaired_n,
                             resolves=resolves_unpaired),
               paired=dict(discordance=a.discordance, mde_points=paired_mde * 100,
                           n_required=paired_n, resolves=resolves_paired),
               minutes_at_n=(n * secs / 60.0) if secs else None,
               minutes_for_required_unpaired=(unpaired_n * secs / 60.0)
               if secs and math.isfinite(unpaired_n) else None,
               minutes_for_required_paired=(paired_n * secs / 60.0)
               if secs and math.isfinite(paired_n) else None)

    L = ["== accuracy: %s at limit=%s ==" % (task, a.limit),
         "  effective n         %s   [%s]" % (_fmt_n(n), prov),
         "  assumed accuracy p  %.3f" % p,
         "  difference asked    %.2f points%s" % (delta * 100,
                                                  " (=%.1f%% relative)" % a.delta if a.relative else ""),
         "  binomial SE         %.3f points   95%% CP interval [%.2f, %.2f]" % (se * 100, lo * 100, hi * 100),
         "",
         "  UNPAIRED (what the harness does today: compare two headline numbers)",
         "    MDE at this n      %s points  @ alpha=%.2f power=%.2f"
         % (("%.2f" % (unpaired_mde * 100)) if not math.isnan(unpaired_mde) else "unreachable",
            a.alpha, a.power),
         "    n needed per arm   %s%s" % (_fmt_n(unpaired_n),
                                          ("  (~%.0f min/arm)" % (unpaired_n * secs / 60.0))
                                          if secs and math.isfinite(unpaired_n) else ""),
         "    verdict            %s" % ("CAN resolve %.2f points" % (delta * 100) if resolves_unpaired
                                        else "CANNOT resolve %.2f points" % (delta * 100)),
         "",
         "  PAIRED / McNemar (same items both sides; needs lm-eval --log_samples)",
         "    assumed discordance psi = %.3f  (fraction of items the two configs answer differently)"
         % a.discordance,
         "    MDE at this n      %s"
         % (("%.2f" % (paired_mde * 100)) if not math.isnan(paired_mde) else "unreachable"),
         "    pairs needed       %s%s" % (_fmt_n(paired_n),
                                          ("  (~%.0f min)" % (paired_n * secs / 60.0))
                                          if secs and math.isfinite(paired_n) else ""),
         "    verdict            %s" % ("CAN resolve %.2f points" % (delta * 100) if resolves_paired
                                        else "CANNOT resolve %.2f points" % (delta * 100))]
    if secs:
        L.append("")
        L.append("  wall clock at this n  ~%.0f min (median %.2f s/sample on this node)"
                 % (n * secs / 60.0, secs))
    L.append("")
    L.append("  NOTE psi is NOT measured anywhere in this repo (eval.sh does not pass")
    L.append("       --log_samples), so the paired column is a projection. The one datum we have")
    L.append("       -- an identical-config mmlu repeat that moved 81.28 -> 81.32 (n=5700) --")
    L.append("       implies psi ~ 0.001 for a config compared with ITSELF. Two DIFFERENT configs")
    L.append("       will discord more; 0.02-0.10 is the defensible planning range.")
    _emit(obj, a.json, L)
    return 0


def _resolve_cv(a):
    if a.cv is not None:
        return a.cv / 100.0, dict(source="--cv", brackets=None), None
    br = throughput_brackets(a.root, a.level, a.model, a.shape, a.scope)
    s = bracket_summary(br)
    if s and s["brackets"] >= a.min_brackets:
        return s["pooled_cv"], dict(source="repo brackets (%s, %s%s)"
                                    % (a.level, a.scope,
                                       ", model~%s" % a.model if a.model else ""), **s), br
    # fall back to the whole-repo pool at this level, and say so
    br2 = throughput_brackets(a.root, a.level, None, a.shape, a.scope)
    s2 = bracket_summary(br2)
    if not s2:
        return None, dict(source="none"), None
    s2["fallback_from"] = "%d bracket(s) for the requested filter (< --min-brackets %d)" \
        % ((s["brackets"] if s else 0), a.min_brackets)
    return s2["pooled_cv"], dict(source="repo brackets (%s, %s, ALL MODELS)" % (a.level, a.scope),
                                 **s2), br2


def cmd_throughput(a):
    cv, meta, br = _resolve_cv(a)
    if cv is None or math.isnan(cv):
        print("no replicate brackets for level=%s scope=%s -- the repo has never measured "
              "this level twice under one config. Pass --cv to plan anyway."
              % (a.level, a.scope), file=sys.stderr)
        return 4
    thr = a.threshold / 100.0
    delta = a.delta / 100.0
    fk = false_keep_prob(thr, cv, a.reps, a.reps_ref, a.estimator)
    pw = keep_power(delta, thr, cv, a.reps, a.reps_ref, a.estimator)
    pw_at_thr = keep_power(thr, thr, cv, a.reps, a.reps_ref, a.estimator)
    mde = mde_throughput(cv, a.reps, a.reps_ref, a.alpha, a.power, a.estimator)
    need_fk = reps_for_threshold(thr, cv, a.max_false_keep, a.estimator)
    need_mde = reps_for_mde(cv, delta, a.alpha, a.power, a.estimator)
    sdf = estimator_sd_factor(a.reps, a.estimator)
    obj = dict(level=a.level, scope=a.scope, estimator=a.estimator, reps=a.reps,
               reps_ref=a.reps_ref, cv=cv, cv_meta={k: v for k, v in meta.items()},
               threshold_pct=a.threshold, delta_pct=a.delta,
               false_keep_prob=fk, power_at_delta=pw, power_at_threshold=pw_at_thr,
               mde_pct=mde * 100, reps_for_false_keep=need_fk, reps_for_mde=need_mde,
               estimator_sd_factor=sdf)
    L = ["== throughput: %s, %s scope, estimator=%s of N=%d ==" % (a.level, a.scope, a.estimator, a.reps)]
    if meta.get("brackets"):
        L.append("  replicate spread    pooled CV %.2f%%  (median %.2f%%, p75 %.2f%%, p90 %.2f%%, "
                 "max %.2f%%) over %d brackets / %d df"
                 % (cv * 100, meta["median_cv"] * 100, meta["p75_cv"] * 100,
                    meta["p90_cv"] * 100, meta["max_cv"] * 100, meta["brackets"], meta["df"]))
    else:
        L.append("  replicate spread    CV %.2f%%  [%s]" % (cv * 100, meta.get("source")))
    L.append("  source              %s" % meta.get("source"))
    if meta.get("fallback_from"):
        L.append("  !! FELL BACK        %s" % meta["fallback_from"])
    L += ["  estimator SD        %.4f x sigma  (a median of %d, not sigma/sqrt(%d)=%.4f)"
          % (sdf, a.reps, a.reps, 1 / math.sqrt(a.reps)),
          "",
          "  KEEP threshold      >%.1f%%" % a.threshold,
          "    false-keep rate    %.1f%%   (rule fires on two IDENTICAL configs)" % (fk * 100),
          "    power at +%.1f%%    %.1f%%   (rule fires on a candidate exactly at the threshold)"
          % (a.threshold, pw_at_thr * 100),
          "    power at +%.1f%%    %.1f%%" % (a.delta, pw * 100),
          "",
          "  two-sided test      MDE %.2f%% at alpha=%.2f power=%.2f" % (mde * 100, a.alpha, a.power),
          "    reps for MDE<=%.1f%%  N=%s per arm" % (a.delta, need_mde if need_mde > 0 else ">999"),
          "    reps for false-keep<=%.0f%%  N=%s per arm"
          % (a.max_false_keep * 100, need_fk if need_fk > 0 else ">999"),
          "",
          "  verdict             %s"
          % ("CAN resolve %.1f%%" % a.delta if mde <= delta else "CANNOT resolve %.1f%% (MDE %.2f%%)"
             % (a.delta, mde * 100))]
    _emit(obj, a.json, L)
    return 0


def cmd_keep_rule(a):
    """The KEEP rule exactly as program.md states it, scored against the repo's own spread."""
    out = {}
    L = ["== the KEEP rule as written, scored against this repo's measured spread ==",
         "   (program.md: median c16 beats current best by >3% AND -- for numeric-risky knobs --",
         "    accuracy within ~1%)", ""]
    for level in ("c1", "c16"):
        br = throughput_brackets(a.root, level, a.model, a.shape, "experiment")
        s = bracket_summary(br)
        if not s:
            L.append("  %-4s no replicate brackets" % level)
            continue
        cv = s["pooled_cv"]
        fk = false_keep_prob(0.03, cv, 3, 3, "median")
        pw = keep_power(0.03, 0.03, cv, 3, 3, "median")
        mde = mde_throughput(cv, 3, 3, 0.05, 0.80, "median")
        need = reps_for_threshold(0.03, cv, 0.05, "median")
        out[level] = dict(pooled_cv=cv, false_keep=fk, power_at_threshold=pw,
                          mde_pct=mde * 100, reps_for_5pct_false_keep=need,
                          brackets=s["brackets"])
        L += ["  %-4s pooled CV %.2f%% over %d brackets" % (level, cv * 100, s["brackets"]),
              "       N=3 medians: false-keep %.1f%%, power at a true +3%% = %.0f%%, MDE %.2f%%"
              % (fk * 100, pw * 100, mde * 100),
              "       N needed for a 5%% false-keep rate: %s" % (need if need > 0 else ">999")]
    L.append("")
    for task, lim in (("gsm8k", 100), ("mmlu", 100), ("mmlu_pro", 100), ("gsm8k", "full"),
                      ("mmlu", "full"), ("mmlu_pro", "full")):
        n, prov = accuracy_effective_n(task, lim, a.root)
        if not n:
            continue
        p = TASK_TYPICAL_P[task]
        mde_u = mde_two_prop(n, p, 0.05, 0.80)
        mde_p = mde_mcnemar(n, a.discordance, 0.05, 0.80)
        secs = TASK_SECONDS_PER_SAMPLE.get(task)
        out["%s@%s" % (task, lim)] = dict(n=n, mde_unpaired_points=mde_u * 100,
                                          mde_paired_points=mde_p * 100,
                                          minutes=(n * secs / 60.0) if secs else None)
        L.append("  %-9s limit=%-4s n=%-6s  MDE unpaired %5s pt | paired(psi=%.2f) %5s pt | ~%4.0f min"
                 % (task, lim, _fmt_n(n),
                    ("%.2f" % (mde_u * 100)) if not math.isnan(mde_u) else "n/a",
                    a.discordance,
                    ("%.2f" % (mde_p * 100)) if not math.isnan(mde_p) else "n/a",
                    (n * secs / 60.0) if secs else float("nan")))
    L += ["",
          "  The 1%-accuracy clause is satisfiable only where MDE <= 1.00 pt.",
          "  The >3%-throughput clause is a THRESHOLD, not a test: at a true +3% it fires",
          "  about half the time by construction, whatever N is."]
    _emit(out, a.json, L)
    return 0


def cmd_variance(a):
    out = {"throughput": {}, "accuracy": {}}
    L = ["== empirical variance, from this repo's own journals ==", ""]
    for scope in ("experiment", "session", "cross"):
        for level in LEVELS:
            br = throughput_brackets(a.root, level, a.model, a.shape, scope)
            s = bracket_summary(br)
            if not s:
                continue
            out["throughput"]["%s/%s" % (scope, level)] = s
            L.append("  %-10s %-4s brackets=%-3d df=%-3d  pooled %.2f%%  median %.2f%%  "
                     "p75 %.2f%%  p90 %.2f%%  max %.2f%%"
                     % (scope, level, s["brackets"], s["df"], s["pooled_cv"] * 100,
                        s["median_cv"] * 100, s["p75_cv"] * 100, s["p90_cv"] * 100,
                        s["max_cv"] * 100))
        L.append("")
    # worst offenders, so an operator can see WHICH configs are noisy
    br = throughput_brackets(a.root, "c16", a.model, a.shape, "experiment")
    br.sort(reverse=True)
    L.append("  noisiest c16 brackets:")
    for cv, k, key, vals in br[:6]:
        L.append("    CV %5.2f%% k=%d  %-42s cfg=%s  %s"
                 % (cv * 100, k, key[0][:42], key[1], [round(v, 2) for v in vals]))
    L.append("")
    # accuracy replicate brackets
    g = defaultdict(list)
    for r in _rows("results/*/*/*/accuracy.tsv", a.root):
        smap = dict(x.split("=", 1) for x in (r.get("samples") or "").split(";") if "=" in x)
        for part in (r.get("scores") or "").split(";"):
            if "=" not in part:
                continue
            t, v = part.split("=", 1)
            try:
                v = float(v)
            except ValueError:
                continue
            eff = smap.get(t, "")
            n = int(eff.split("/")[0]) if "/" in eff and eff.split("/")[0].isdigit() else None
            g[(r["model"], r["config_hash"], t, r["limit"], r["think"], r["conc"])].append(
                (v, n, r["status"], r["run_id"]))
    L.append("  accuracy replicate brackets (identical model+config+task+limit+think+conc):")
    nb = 0
    for key, v in sorted(g.items()):
        if len(v) < 2:
            continue
        nb += 1
        vals = [x[0] for x in v]
        bad = [x for x in v if x[2] in ("void", "suspect", "crash")]
        out["accuracy"]["|".join(map(str, key))] = dict(values=vals, n=v[0][1],
                                                        range=max(vals) - min(vals),
                                                        nonciteable=len(bad))
        L.append("    %-38s %-9s lim=%-4s n=%-5s %s range=%.2f pt%s"
                 % (key[0][:38], key[2], key[3], v[0][1], vals, max(vals) - min(vals),
                    "  [%d non-citable]" % len(bad) if bad else ""))
    L.append("    -> %d brackets total; that is the ENTIRE empirical basis for accuracy" % nb)
    L.append("       repeatability in this repo.")
    _emit(out, a.json, L)
    return 0


def cmd_seed(a):
    """What does AHL_SEED=42 (identical synthetic prompts on both sides) actually buy?

    bench.sh pins the GuideLLM seed, so a candidate and its reference are issued the SAME
    sequence of (prompt_tokens, output_budget) draws. That removes the workload-composition
    term from the variance of a comparison. This subcommand MEASURES that term instead of
    asserting it, by bootstrapping the request pool of each retained c1 bundle:

        Var(unpaired difference) = Var(machine) + Var(workload draw)
        Var(paired   difference) = Var(machine)

    Var(machine) is what the replicate brackets already measure (they are all seed=42).
    Var(workload draw) is what the bootstrap below estimates.

    c1 only: at c1 requests are served one at a time, so resampling the request pool is a
    legitimate model of 'draw a different prompt set'. At c16 the requests interact through
    the batch and the bootstrap would be wrong, so this refuses to report it -- see the
    analysis doc for the scaling argument instead.
    """
    runs = sorted(glob.glob(os.path.join(a.root, "results/*/*/*/data/*-chat")))
    rnd = random.Random(a.seed)
    boot, tail, nreq, budget = [], [], [], []
    for run in runs:
        p = os.path.join(run, "level_c1.json")
        if not os.path.exists(p):
            continue
        try:
            d = json.load(open(p))
            b = d["benchmarks"][0]
        except Exception:
            continue
        rows = [(r.get("output_tokens"), r.get("request_latency"))
                for r in (b["requests"].get("successful") or [])]
        rows = [(o, l) for o, l in rows if o and l and l > 0]
        n = len(rows)
        if n < a.min_requests:
            continue
        nreq.append(n)

        def T(seq):
            return sum(x[0] for x in seq) / sum(x[1] for x in seq)

        bs = [T([rows[rnd.randrange(n)] for _ in range(n)]) for _ in range(a.boot)]
        boot.append(statistics.pstdev(bs) / statistics.mean(bs))
        # the part pairing does NOT fix: a faster config completes MORE of the same sequence,
        # so the two sides average different prefixes of it.
        lo = max(3, int(n * 0.85))
        pre = [T(rows[:k]) for k in range(lo, n + 1)]
        tail.append(statistics.pstdev(pre) / statistics.mean(pre))
        budget.append(statistics.pstdev([x[0] for x in rows]) / statistics.mean([x[0] for x in rows]))
    if not boot:
        print("no c1 bundles with per-request records under %s/results (they are gitignored; "
              "point --root at a checkout that has them)" % a.root, file=sys.stderr)
        return 4

    def med(v):
        return statistics.median(v)
    br = throughput_brackets(a.root, "c1", None, "chat", "experiment")
    s = bracket_summary(br)
    obj = dict(bundles=len(boot), median_requests=med(nreq), budget_cv=med(budget),
               workload_cv_median=med(boot), workload_cv_pooled=math.sqrt(
                   sum(x * x for x in boot) / len(boot)),
               ragged_tail_cv=med(tail), bands={})
    L = ["== what the fixed seed buys, at c1, from %d retained bundles ==" % len(boot),
         "  median requests per c1 stage      %.0f" % med(nreq),
         "  output-budget CV within a stage   %.1f%%   (this is what the seed holds identical)"
         % (med(budget) * 100),
         "  ragged-tail residual              %.2f%%   pairing does NOT fix this: the faster"
         % (med(tail) * 100),
         "                                            config completes more of the same",
         "                                            sequence, so the two sides average",
         "                                            different prefixes of it.",
         "",
         "  band            machine SD   workload SD   unpaired SD   SD ratio   ~replicates",
         "  ------------------------------------------------------------------------------"]
    for name, machine, workload in (("typical (median)", s["median_cv"], med(boot)),
                                    ("planning (pooled)", s["pooled_cv"],
                                     math.sqrt(sum(x * x for x in boot) / len(boot)))):
        unp = math.hypot(machine, workload)
        r = unp / machine if machine else float("nan")
        obj["bands"][name] = dict(machine_cv=machine, workload_cv=workload, unpaired_cv=unp,
                                  sd_ratio=r, reps_equivalent=r * r)
        L.append("  %-16s %8.2f%%   %9.2f%%   %9.2f%%   %7.2fx   %8.1fx"
                 % (name, machine * 100, workload * 100, unp * 100, r, r * r))
    # c16 scaling: the workload term shrinks like 1/sqrt(requests in the stage), and a c16
    # stage completes an order of magnitude more requests than a c1 stage.
    n16 = []
    for run in runs:
        p = os.path.join(run, "level_c16.json")
        if not os.path.exists(p):
            continue
        try:
            n16.append(len(json.load(open(p))["benchmarks"][0]["requests"]["successful"]))
        except Exception:
            pass
    if n16:
        scale = math.sqrt(med(nreq) / med(n16))
        s16 = bracket_summary(throughput_brackets(a.root, "c16", None, "chat", "experiment"))
        w16 = med(boot) * scale
        r16 = math.hypot(s16["median_cv"], w16) / s16["median_cv"]
        obj["c16_projection"] = dict(median_requests=med(n16), workload_cv=w16,
                                     machine_cv=s16["median_cv"], sd_ratio=r16)
        L += ["",
              "  c16 projection (bootstrap is invalid there -- requests interact through the",
              "  batch -- so this is the 1/sqrt(n) scaling of the c1 term, not a measurement):",
              "    median requests per c16 stage %.0f vs %.0f at c1 -> workload term ~%.2f%%,"
              % (med(n16), med(nreq), w16 * 100),
              "    against a machine term of %.2f%% -> pairing is worth %.2fx there. Effectively"
              % (s16["median_cv"] * 100, r16),
              "    nothing, which matters because c16 IS the tuned objective."]
    L += ["",
          "  Read this as: the pairing is real, free, and worth keeping -- about %.1fx the"
          % obj["bands"]["planning (pooled)"]["reps_equivalent"],
          "  replicates at c1. But it is not what makes Gate 3 hard: at the c16 objective the",
          "  machine term dominates and no amount of seed-pinning touches it."]
    _emit(obj, a.json, L)
    return 0


def _load_sample_correctness(path: str):
    """Map doc_id -> 0/1 from an lm-eval --log_samples jsonl."""
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            key = d.get("doc_id", d.get("doc_hash", len(out)))
            score = None
            for k, v in d.items():
                if k in ("acc", "exact_match", "acc_norm") and isinstance(v, (int, float)):
                    score = float(v)
                    break
            if score is None:
                for k, v in d.items():
                    if k.startswith(("acc", "exact_match")) and isinstance(v, (int, float)):
                        score = float(v)
                        break
            if score is not None:
                out[key] = 1 if score >= 0.5 else 0
    return out


def cmd_mcnemar(a):
    if a.samples:
        A = _load_sample_correctness(a.samples[0])
        B = _load_sample_correctness(a.samples[1])
        keys = sorted(set(A) & set(B))
        if not keys:
            print("no shared doc ids between the two sample files", file=sys.stderr)
            return 2
        b = sum(1 for k in keys if A[k] == 1 and B[k] == 0)
        c = sum(1 for k in keys if A[k] == 0 and B[k] == 1)
        n = len(keys)
    else:
        b, c, n = a.b, a.c, a.n or (a.b + a.c)
    disc = b + c
    p = binom_test_two_sided(b, disc, 0.5) if disc else 1.0
    psi = disc / n if n else float("nan")
    diff = (b - c) / n if n else float("nan")
    lo, hi = clopper_pearson(b, disc, a.alpha) if disc else (float("nan"), float("nan"))
    obj = dict(n=n, b=b, c=c, discordant=disc, discordance=psi, diff_points=diff * 100,
               exact_p=p, prop_b_ci=[lo, hi])
    L = ["== exact McNemar ==",
         "  pairs              %s" % _fmt_n(n),
         "  A right / B wrong  %d" % b,
         "  A wrong / B right  %d" % c,
         "  discordant         %d   (psi = %.4f)" % (disc, psi),
         "  difference         %+.2f points" % (diff * 100),
         "  exact two-sided p  %.4g" % p,
         "  verdict            %s at alpha=%.2f" % ("DIFFERENT" if p < a.alpha else "not separable",
                                                    a.alpha)]
    if n:
        L.append("  MDE at this n/psi  %.2f points (alpha .05, power .80)"
                 % (mde_mcnemar(n, max(psi, 1e-6), 0.05, 0.80) * 100))
    _emit(obj, a.json, L)
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# selftest
# ─────────────────────────────────────────────────────────────────────────────

def _close(got, want, tol, what, fails):
    if not (abs(got - want) <= tol):
        fails.append("%s: got %.10g want %.10g (tol %.3g)" % (what, got, want, tol))
        return False
    print("  ok   %-52s %.6g ~ %.6g" % (what, got, want))
    return True


def cmd_selftest(a):
    fails = []
    print("-- normal quantiles (stdlib NormalDist, sanity) --")
    _close(norm_ppf(0.975), 1.959963985, 1e-8, "norm_ppf(0.975)", fails)
    _close(norm_ppf(0.80), 0.8416212336, 1e-8, "norm_ppf(0.80)", fails)
    _close(norm_cdf(1.959963985), 0.975, 1e-9, "norm_cdf(1.95996)", fails)

    print("-- regularized incomplete beta (hand-computable) --")
    # I_.5(2,3) = P(Bin(4,.5) >= 2) = (6+4+1)/16 = 11/16
    _close(betainc(0.5, 2, 3), 11.0 / 16.0, 1e-12, "betainc(.5,2,3) = 11/16", fails)
    _close(betainc(0.3, 1, 1), 0.3, 1e-12, "betainc(.3,1,1) = x", fails)
    # I_x(a,b) = 1 - I_{1-x}(b,a)
    _close(betainc(0.37, 3.5, 2.25) + betainc(0.63, 2.25, 3.5), 1.0, 1e-12,
           "betainc symmetry", fails)
    _close(betainc_inv(betainc(0.42, 4, 7), 4, 7), 0.42, 1e-9, "betainc_inv round-trip", fails)

    print("-- Student-t quantiles vs published table --")
    for df, want in ((2, 4.302653), (3, 3.182446), (5, 2.570582), (10, 2.228139),
                     (30, 2.042272), (100, 1.983972)):
        _close(t_ppf(0.975, df), want, 1e-5, "t_ppf(.975, df=%d)" % df, fails)
    _close(t_cdf(t_ppf(0.9, 7), 7), 0.9, 1e-10, "t_cdf/t_ppf round-trip", fails)

    print("-- exact binomial --")
    _close(binom_cdf(3, 10, 0.5), 176.0 / 1024.0, 1e-12, "P(X<=3 | 10, .5) = 176/1024", fails)
    _close(binom_cdf(0, 5, 0.2), 0.8 ** 5, 1e-12, "P(X<=0 | 5, .2) = .8^5", fails)
    # exact McNemar on b=8,c=2: 2*P(X<=2 | 10,.5) = 2*56/1024
    _close(binom_test_two_sided(8, 10, 0.5), 2.0 * 56.0 / 1024.0, 1e-12,
           "exact McNemar p (b=8,c=2)", fails)
    # Clopper-Pearson, published values
    lo, hi = clopper_pearson(2, 20, 0.05)
    _close(lo, 0.012347, 1e-5, "Clopper-Pearson lower (2/20)", fails)
    _close(hi, 0.316979, 1e-5, "Clopper-Pearson upper (2/20)", fails)
    lo0, hi0 = clopper_pearson(0, 10, 0.05)
    _close(hi0, 0.308495, 1e-5, "Clopper-Pearson upper (0/10)", fails)

    print("-- SD of the sample median (published efficiency table + Monte Carlo) --")
    # relative efficiency of the normal median at finite n: Var(median) = (1/n)/eff.
    # Odd and even n follow DIFFERENT sequences, so both quadratures are checked.
    for n, eff in ((3, 0.7430), (5, 0.6968), (7, 0.6790), (9, 0.6693),      # odd
                   (4, 0.838), (6, 0.776), (8, 0.743), (10, 0.723)):        # even
        _close(median_sd_factor(n), math.sqrt((1.0 / n) / eff), 6e-4,
               "median_sd_factor(%d) [%s]" % (n, "odd" if n % 2 else "even"), fails)
    _close(median_sd_factor(2), 1 / math.sqrt(2), 1e-12, "median_sd_factor(2)=mean of 2", fails)
    # the even-n joint density must integrate to 1 -- that is what pins the constant AND the
    # triangular-domain quadrature together. A product-Simpson rule over the square failed here.
    # (the mass error grows slowly with n as the density concentrates: ~7e-8 at n=4,
    #  ~9e-6 at n=30, still orders of magnitude below anything a decision turns on)
    for n, tol in ((4, 1e-6), (10, 1e-5), (30, 5e-5), (50, 5e-4)):
        _close(_median_var_even(n, check=True)[1], 1.0, tol,
               "even-n joint density integrates to 1 (n=%d)" % n, fails)
    rnd = random.Random(11)
    for n in (3, 4):
        mc = math.sqrt(sum(statistics.median([rnd.gauss(0, 1) for _ in range(n)]) ** 2
                           for _ in range(200000)) / 200000)
        _close(median_sd_factor(n), mc, 5e-3, "median_sd_factor(%d) vs 200k MC" % n, fails)
    # the switch to the asymptotic form must not jump
    _close(median_sd_factor(_ASYMPTOTIC_FROM),
           math.sqrt(math.pi / (2.0 * _ASYMPTOTIC_FROM)), 6e-3,
           "quadrature meets the asymptote at n=%d" % _ASYMPTOTIC_FROM, fails)
    if not all(median_sd_factor(n) > median_sd_factor(n + 1) for n in range(2, 80)):
        fails.append("median_sd_factor is not strictly decreasing in n (parity seam?)")
    else:
        print("  ok   median_sd_factor strictly decreasing across the parity seam")

    print("-- two-proportion sample size vs published tables --")
    # Fleiss, uncorrected: p1=.25 vs p2=.50, alpha .05, power .80 -> 58 per arm
    _close(math.ceil(n_two_prop(0.25, 0.50)), 58, 0, "n_two_prop(.25,.50) = 58/arm", fails)
    # round-trip: power at the returned n must be >= target and < target at n-1
    n58 = n_two_prop(0.25, 0.50)
    if not (power_two_prop(math.ceil(n58), 0.25, 0.50) >= 0.80 >
            power_two_prop(math.ceil(n58) - 1, 0.25, 0.50)):
        fails.append("n_two_prop/power_two_prop are not inverses")
    else:
        print("  ok   n_two_prop <-> power_two_prop round-trip")
    _close(mde_two_prop(n_two_prop(0.90, 0.85), 0.90), 0.05, 1e-4,
           "mde_two_prop inverts n_two_prop", fails)

    print("-- two-proportion power vs seeded Monte Carlo --")
    # The analytic form is the standard normal approximation; the MC applies the pooled-SE
    # z-test to actual binomial draws. They agree to ~1 point, with MC slightly HIGH. A gap
    # bigger than 2 points would mean the formula is wrong, not merely approximate.
    rnd = random.Random(4242)
    n = 200
    p1, p2 = 0.90, 0.80
    want = power_two_prop(n, p1, p2)
    hits = 0
    REPS = 20000
    za = norm_ppf(0.975)
    for _ in range(REPS):
        x1 = sum(1 for _ in range(n) if rnd.random() < p1)
        x2 = sum(1 for _ in range(n) if rnd.random() < p2)
        ph = (x1 + x2) / (2.0 * n)
        se = math.sqrt(2.0 * ph * (1 - ph) / n)
        if se > 0 and abs(x1 / n - x2 / n) / se > za:
            hits += 1
    _close(hits / REPS, want, 0.02, "MC power(two-prop, n=200, .90/.80)", fails)

    print("-- McNemar sample size vs seeded Monte Carlo --")
    # Connor's normal-approximation n is validated against the EXACT conditional test, which is
    # discrete and therefore conservative: empirical power lands a little BELOW the nominal 0.80
    # (~0.78 here). That direction is expected; power materially above 0.80 would mean the
    # sample-size formula is too generous, which is the failure that matters.
    psi, delta = 0.15, 0.05          # p01=.10, p10=.05 -> Connor's worked example
    npairs = n_mcnemar(psi, delta)
    _close(npairs, 468.6, 1.5, "n_mcnemar(psi=.15, delta=.05) ~ 469 pairs", fails)
    p10 = (psi - delta) / 2.0
    p01 = p10 + delta
    rnd = random.Random(99)
    N = int(math.ceil(npairs))
    hits = 0
    REPS = 4000
    for _ in range(REPS):
        b = c = 0
        for _ in range(N):
            u = rnd.random()
            if u < p01:
                b += 1
            elif u < p01 + p10:
                c += 1
        d = b + c
        if d and binom_test_two_sided(b, d, 0.5) < 0.05:
            hits += 1
    _close(hits / REPS, 0.80, 0.03, "MC power of exact McNemar at n_mcnemar()", fails)
    _close(power_mcnemar(npairs, psi, delta), 0.80, 1e-3, "power_mcnemar inverts n_mcnemar", fails)
    _close(mde_mcnemar(npairs, psi), delta, 1e-4, "mde_mcnemar inverts n_mcnemar", fails)

    print("-- throughput decision rule vs seeded Monte Carlo --")
    cv, thr, reps = 0.025, 0.03, 3
    want = false_keep_prob(thr, cv, reps, reps, "median")
    rnd = random.Random(777)
    REPS = 60000
    hits = 0
    for _ in range(REPS):
        a_ = statistics.median([rnd.gauss(0, 1) * cv for _ in range(reps)])
        b_ = statistics.median([rnd.gauss(0, 1) * cv for _ in range(reps)])
        if (1 + a_) / (1 + b_) > 1 + thr:
            hits += 1
    _close(hits / REPS, want, 0.006, "MC false-keep(N=3 medians, CV 2.5%, >3%)", fails)
    # a true +3% candidate must fire ~50% of the time, whatever N -- it is a threshold
    for n in (3, 9, 25):
        _close(keep_power(0.03, 0.03, cv, n, n, "median"), 0.5, 1e-9,
               "power at the threshold is 50%% (N=%d)" % n, fails)
    # monotonicity
    if not (false_keep_prob(thr, cv, 3, 3) > false_keep_prob(thr, cv, 9, 9) >
            false_keep_prob(thr, cv, 25, 25)):
        fails.append("false_keep_prob is not decreasing in N")
    else:
        print("  ok   false-keep decreases with N")
    if not (mde_throughput(0.01, 3, 3) < mde_throughput(0.05, 3, 3)):
        fails.append("mde_throughput is not increasing in CV")
    else:
        print("  ok   MDE increases with CV")
    n_need = reps_for_mde(cv, 0.03)
    if not (mde_throughput(cv, n_need, n_need) <= 0.03 <
            mde_throughput(cv, n_need - 1, n_need - 1)):
        fails.append("reps_for_mde is not the smallest N")
    else:
        print("  ok   reps_for_mde returns the smallest sufficient N")

    print("-- pooled CV estimator --")
    # three synthetic brackets with known SDs must pool to the rms
    fake = [(0.02, 3, None, None), (0.04, 3, None, None), (0.06, 3, None, None)]
    _close(pooled_cv(fake), math.sqrt((0.0004 + 0.0016 + 0.0036) / 3), 1e-12,
           "pooled_cv = rms when df are equal", fails)

    print("-- effective-n arithmetic (the LIMIT=100 trap) --")
    n_mmlu, _ = accuracy_effective_n("mmlu", 100, a.root)
    n_gsm, _ = accuracy_effective_n("gsm8k", 100, a.root)
    n_pro, _ = accuracy_effective_n("mmlu_pro", 100, a.root)
    for got, want, what in ((n_mmlu, 5700, "mmlu@100 -> 5700 (57 leaves)"),
                            (n_pro, 1400, "mmlu_pro@100 -> 1400 (14 leaves)"),
                            (n_gsm, 100, "gsm8k@100 -> 100 (1 leaf)")):
        if got != want:
            fails.append("%s: got %r" % (what, got))
        else:
            print("  ok   %-52s %d" % (what, got))

    print()
    if fails:
        print("FAIL (%d):" % len(fails))
        for f in fails:
            print("  - " + f)
        return 1
    print("all self-checks passed")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=REPO_ROOT, help="repo root (for results/*/*/*/*.tsv)")
    ap.add_argument("--json", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("accuracy", help="binomial power for a Gate-2 comparison")
    q.add_argument("--task", default="mmlu")
    q.add_argument("--limit", default="100")
    q.add_argument("--n", type=int, help="override the effective sample count")
    q.add_argument("--p", type=float, help="assumed accuracy (default: task-typical)")
    q.add_argument("--delta", type=float, default=1.0,
                   help="difference you care about, in POINTS (or percent if --relative)")
    q.add_argument("--relative", action="store_true", help="treat --delta as a relative percent")
    q.add_argument("--discordance", type=float, default=0.05,
                   help="psi for the paired column: fraction of items the two configs answer "
                        "differently (default 0.05)")
    q.add_argument("--alpha", type=float, default=0.05)
    q.add_argument("--power", type=float, default=0.80)
    q.set_defaults(fn=cmd_accuracy)

    t = sub.add_parser("throughput", help="empirical power for a Gate-3 comparison")
    t.add_argument("--level", default="c16", choices=LEVELS)
    t.add_argument("--model", help="substring filter; falls back to all models if too few brackets")
    t.add_argument("--shape", default="chat", help="substring of the shape column")
    t.add_argument("--scope", default="experiment", choices=("experiment", "session", "cross"))
    t.add_argument("--reps", type=int, default=3, help="N for the candidate")
    t.add_argument("--reps-ref", type=int, default=3, help="N for the reference")
    t.add_argument("--estimator", default="median", choices=("median", "mean"))
    t.add_argument("--threshold", type=float, default=3.0, help="KEEP threshold, relative percent")
    t.add_argument("--delta", type=float, default=3.0, help="true effect you care about, percent")
    t.add_argument("--cv", type=float, help="override the empirical CV, in percent")
    t.add_argument("--alpha", type=float, default=0.05)
    t.add_argument("--power", type=float, default=0.80)
    t.add_argument("--max-false-keep", type=float, default=0.05)
    t.add_argument("--min-brackets", type=int, default=8)
    t.set_defaults(fn=cmd_throughput)

    k = sub.add_parser("keep-rule", help="score the KEEP rule as written")
    k.add_argument("--model")
    k.add_argument("--shape", default="chat")
    k.add_argument("--discordance", type=float, default=0.05)
    k.set_defaults(fn=cmd_keep_rule)

    v = sub.add_parser("variance", help="dump the empirical variance tables")
    v.add_argument("--model")
    v.add_argument("--shape", default="chat")
    v.set_defaults(fn=cmd_variance)

    sd = sub.add_parser("seed", help="measure what AHL_SEED=42 pairing buys (needs raw bundles)")
    sd.add_argument("--boot", type=int, default=300)
    sd.add_argument("--seed", type=int, default=7)
    sd.add_argument("--min-requests", type=int, default=10)
    sd.set_defaults(fn=cmd_seed)

    m = sub.add_parser("mcnemar", help="exact paired test")
    m.add_argument("--b", type=int, default=0, help="A right, B wrong")
    m.add_argument("--c", type=int, default=0, help="A wrong, B right")
    m.add_argument("--n", type=int, help="total pairs (default b+c)")
    m.add_argument("--samples", nargs=2, metavar=("A.jsonl", "B.jsonl"),
                   help="two lm-eval --log_samples files")
    m.add_argument("--alpha", type=float, default=0.05)
    m.set_defaults(fn=cmd_mcnemar)

    s = sub.add_parser("selftest", help="numeric self-checks")
    s.set_defaults(fn=cmd_selftest)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
