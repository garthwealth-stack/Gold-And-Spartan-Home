"""
indicators.py — pure-numpy EMA / ATR / ADX, identical maths to the EA
and to the Python backtests, so the executor's signals match the MQL5 EA.
"""
import numpy as np


def ema(x, n):
    x = np.asarray(x, dtype=float)
    k = 2.0 / (n + 1.0)
    out = np.empty_like(x)
    out[0] = x[0]
    for i in range(1, len(x)):
        out[i] = x[i] * k + out[i - 1] * (1 - k)
    return out


def atr(h, l, c, n):
    h, l, c = map(lambda z: np.asarray(z, float), (h, l, c))
    tr = np.empty(len(c))
    tr[0] = h[0] - l[0]
    for i in range(1, len(c)):
        tr[i] = max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
    out = np.full(len(c), np.nan)
    if len(c) > n:
        out[n] = tr[1:n + 1].mean()
        for i in range(n + 1, len(c)):
            out[i] = (out[i - 1] * (n - 1) + tr[i]) / n
    return out


def adx(h, l, c, n):
    h, l, c = map(lambda z: np.asarray(z, float), (h, l, c))
    m = len(c)
    plus_dm = np.zeros(m); minus_dm = np.zeros(m); tr = np.zeros(m)
    for i in range(1, m):
        up = h[i] - h[i - 1]
        dn = l[i - 1] - l[i]
        plus_dm[i] = up if (up > dn and up > 0) else 0.0
        minus_dm[i] = dn if (dn > up and dn > 0) else 0.0
        tr[i] = max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))

    def wilder(v):
        out = np.full(m, np.nan)
        if m > n:
            out[n] = v[1:n + 1].sum()
            for i in range(n + 1, m):
                out[i] = out[i - 1] - out[i - 1] / n + v[i]
        return out

    tr_s = wilder(tr); pdm_s = wilder(plus_dm); mdm_s = wilder(minus_dm)
    pdi = 100 * pdm_s / tr_s
    mdi = 100 * mdm_s / tr_s
    dx = 100 * np.abs(pdi - mdi) / (pdi + mdi)
    adx_out = np.full(m, np.nan)
    first = n * 2
    if m > first:
        adx_out[first] = np.nanmean(dx[n + 1:first + 1])
        for i in range(first + 1, m):
            adx_out[i] = (adx_out[i - 1] * (n - 1) + dx[i]) / n
    return adx_out, pdi, mdi
