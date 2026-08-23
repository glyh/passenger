# 035: what each `checkVisibility()` option costs and buys

Measured 2026-08-23, against the live session. Four walker variants evaluated
against the same page in the same navigation, so each row is a before/after on
one document rather than a comparison across fetches.

    A_today   node.checkVisibility()
    B_vis     node.checkVisibility({visibilityProperty: true})
    C_vis_op  node.checkVisibility({visibilityProperty: true, opacityProperty: true})
    D_all     ... plus contentVisibilityAuto: true

## 025's five pages, the acceptance set

Characters of `dom` output after `tidy`.

| Page | A_today | B_vis | C_vis_op | D_all |
|---|---|---|---|---|
| chinadaily | 5,575 | 5,452 | 5,452 | 5,452 |
| chinanews | 4,851 | 4,851 | 4,851 | 4,851 |
| gmw | 5,977 | 5,977 | 5,977 | 5,977 |
| americanthinker | 50,113 | 50,113 | 50,052 | 50,052 |
| moonofalabama | 81,458 | 81,458 | 81,458 | 81,458 |

What `B_vis` removes, in full -- two lines, on one page:

    - [China Daily PDF](http://newspress.chinadaily.net.cn/)
    - [China Daily E-paper](https://epaper.chinadaily.com.cn/china)

What `C_vis_op` removes beyond that -- three lines, on one page:

    Link copied
    #### Ad Free / Commenting Login
    Email Password

Both sets are furniture: a hidden nav pair, a copy-confirmation toast, and the
labels of a login dialog that is not open. `D_all` removed nothing anywhere
beyond `C_vis_op`.

## The risk probe

The acceptance set answers *does this help on the pages we care about*. It does
not exercise the failure the ticket named for `opacityProperty` -- scroll-
triggered reveal, which holds content at `opacity: 0` until the reader arrives.
`fetch` is goto-settle-read and never scrolls, so that content would be dropped
rather than deferred. Four pages chosen for the risk, not for the verdict:

| Page | A_today | B_vis | C_vis_op | lines dropped by C |
|---|---|---|---|---|
| apple.com/macbook-pro | 13,081 | 13,069 | **3,761** | **125** |
| stripe.com/blog | 8,958 | 8,958 | 8,958 | 0 |
| vercel.com/blog | 91 | 91 | 91 | 0 |
| developer.mozilla.org (content-visibility) | 0 | 0 | 0 | 0 |

apple.com is the case, and it is not marginal: **71% of the page**, and what
goes is body text, not chrome --

    - M5, M5 Pro, and M5 Max chips
    - AI
    - Battery life
    - macOS Tahoe
    - Phone app and Live Activities

Two side observations, recorded because they were surprising and are not this
ticket's to chase. `dom` returns **0 characters** on that MDN page and **91**
on vercel.com/blog; both are JS-rendered and neither is a `checkVisibility`
problem, since all four variants agree. The MDN result also means
`contentVisibilityAuto` was never actually exercised -- the page picked to
exercise it gave nothing back.

## Verdict

**Take `visibilityProperty`. Refuse `opacityProperty`. Leave
`contentVisibilityAuto` alone.**

- `visibilityProperty` buys hidden furniture removal on 1 of 9 pages and cost
  nothing on any of them. Small, free, and it makes the call mean what its name
  says.
- `opacityProperty` buys three lines of dialog chrome and costs 71% of a real
  page. The asymmetry is the whole argument: furniture surviving is a cost,
  content vanishing is a lie, and a tool that never scrolls cannot tell a
  hidden element from one waiting for a reader.
- `contentVisibilityAuto` changed nothing measurable anywhere, and the one page
  chosen to test it returned nothing. That is untested, not safe, and taking a
  change with no measured benefit and a named risk -- long documents defer
  their below-the-fold body with exactly this property -- is the wrong trade.

Revisit `opacityProperty` only with a mechanism that can distinguish a hidden
element from an unfinished one. Nothing available here can.
