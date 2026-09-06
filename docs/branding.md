# Branding

The logo, the colours, and — more importantly — the two trademark policies that
constrain both. Checked against the primary sources on 2026-09-05.

**None of this is legal advice.** Where a real answer is needed, both policies
name a contact.

## The mark

`assets/logo.svg` is an isometric cube with three flat faces. The front-right
face is `#386EE0` and carries an **existential quantifier**, projected onto the
plane of that face.

`assets/logo-wordmark.svg` is the same cube with the word `infra` beside it.
The wordmark is set in a system font stack rather than converted to outlines:
this is a project mark, not a registered one, and a missing font should degrade
to a readable word.

| Role | Hex |
|---|---|
| Front-right face — the Lean-blue one | `#386EE0` |
| Top face | `#7C93B4` |
| Front-left face | `#3F5372` |
| The `∃`, and nothing else | `#FFFFFF` |

The cube's three fills read on both light and dark backgrounds, so only the
wordmark text is theme-switched (`prefers-color-scheme` inside the SVG).

## Why it is not more like OpenTofu's

The brief was "similar to the box of OpenTofu". The resemblance was
deliberately limited, because OpenTofu's mark is governed by the **Linux
Foundation trademark policy** (OpenTofu is a Series of LF Projects, and its
`brand-artifacts` repo licenses the *artwork* under MPL-2.0 while explicitly
routing the *marks* to the LF policy — MPL-2.0 §1.9 grants no trademark
rights). That policy says, verbatim:

> A trademark should not be incorporated into your company's logos or designs.

> use of marks that are confusingly similar to trademarks of LF Projects, is
> prohibited

So the shared element is only the isometric cube, which is a generic and
un-ownable shape used by many projects. What carries OpenTofu's distinctiveness
was avoided on purpose:

| Their mark | Ours |
|---|---|
| Two closed eyes on the front-left face — it is a mascot, a face | no face, ever; a mathematical symbol instead |
| Yellow `#feda15` + white + a heavy `#0d1a2a` keyline | blue and slate, no keyline |
| Rounded corners with a thick dark gutter between faces | square corners, faces meeting directly |
| Cube set small and superscript *after* the wordmark | cube at full size *before* the wordmark |

The eyes are the single most identifying feature and are not reused in any
form. If the resemblance ever needs a real ruling, the contact is
`trademarks@linuxfoundation.org`.

## Why the blue is what it is, and why there is no Lean logo on the page

Two things worth being precise about, because both are easy to get wrong.

**`#386EE0` is not an official Lean logo colour.** Every official Lean logo
file is monochrome `#070000`, with a `#B7B7B7` ™. `#386EE0` is the Lean
*website's* primary colour — it is the `--color-primary` token and the literal
`stroke` on the nav mark at lean-lang.org. It is the blue people mean when they
say "Lean blue", but no Lean brand guide states it, because there is no Lean
brand guide. (There is also **no purple** anywhere in official Lean assets, in
case that comes up.)

**The `∃` is a mathematical symbol, not a piece of the Lean mark.** The Lean
trademark is the name and "the stylized version of the Lean name with backwards
'E' and upside down 'A'" — that is, the L∃∀N wordmark as a whole. A standalone
existential quantifier is ordinary mathematical notation and is not theirs.
This distinction is what the logo relies on, and it matters, because the Lean
FRO's policy is unusually direct:

> Creating a derived logo from the Lean Trademarks always requires permission.
> We will usually not allow this in order to avoid placing a confusing logo
> into wide-spread use.

So: no Lean logo, no Lean-derived mark, and no L∃∀N wordmark anywhere in this
project's artwork.

What the same policy *does* permit without asking, and which the site uses:

> Stating accurately that software is written in the Lean programming language
> and proof assistant … is allowed. In those cases, you may use the Lean name,
> or stylized name, to indicate this, without prior approval.

with the constraint that the name is an **adjective followed by a generic
noun** — "the Lean programming language and proof assistant", never "Lean" as a
bare noun. Both the site and the README follow that form, and the site footer
disclaims affiliation with the Lean FRO, OpenTofu and the Linux Foundation.

If we ever want to display the actual Lean logo, it must be the unmodified
official file with the ™ intact, and it must not be arranged so a casual
observer would read it as endorsement.

## The cloud marks are names, not logos

As of 2026-09-06 this is **mixed**, deliberately, and the two halves are
governed differently.

**AWS, Google Cloud and Scaleway are those vendors' own marks**, installed
byte-identical to what was downloaded. `assets/providers/SOURCES.md` is the
ledger: where each came from, when, what the host says about its licence, and
— the part that matters — that all three carry a `trademarked` restriction
which the copyright licence does not touch. Apache-2.0 §6 declines to grant
trademark rights explicitly; a public-domain dedication of a *file* says
nothing about the *mark*. Read that file before touching any of the three.

They came from Wikipedia and Wikimedia Commons at the repository owner's
explicit direction, which is a step below what the section below asks for, and
recorded as such rather than quietly. They were checked on arrival — no
scripts, no external references, each vendor's real colours — so they are not
wrong; they are simply not authoritative, and a vendor rebrand will not reach
them.

**Azure and OVHcloud are still wordmarks set in this project's own type**,
supplied as a light/dark pair. Those are not their logos, and the distinction
is the point: naming a product you interoperate with is nominative use, while
reproducing its mark is a different act.

### Contrast without recolouring

All three real marks are dark-on-light artwork — `#252F3E` text for AWS,
`#5f6368` for Google Cloud's wordmark, `#521094` for Scaleway. On a dark page
the first is invisible and the others are poor.

The obvious fix is the forbidden one. Recolouring a vendor's mark to make a
reversed variant produces a *modified* mark, which is what their guidelines
prohibit and what the note further down already warned about. A vendor that
publishes only one variant has, in effect, said it should not be inverted.

So the marks are not touched, and the *tile* changes instead: in dark mode the
three vendor tiles get a white plate (`.cloud.has-mark`), which is the
sanctioned way to carry dark-on-light artwork onto a dark background. The two
wordmark tiles beside them do not get a plate, because they are ours and
invert cleanly.

If an official reversed file is ever obtained for one of the three, it belongs
at `<name>-dark.svg` and that tile can drop its plate. The socket below is
still the mechanism. They are not AWS's or Scaleway's
logos, and that is deliberate: the same caution that applies to Lean and
OpenTofu applies here, and AWS's guidelines in particular are strict about
their marks.

Naming a product you interoperate with is nominative use and is ordinarily
fine; reproducing its logo is a different act.

### The strip shows supported clouds only

It used to list planned ones too, greyed, with "planned" tags — on the
reasoning that they cost nothing. They did cost something: a strip that mixes
supported and unsupported clouds is a roadmap as much as a statement of
support, and a roadmap on a landing page is the thing most likely to be read as
a promise. It now shows AWS, Google Cloud and Scaleway, which are exactly the
clouds that have a client.

`azure.svg`, `ovh.svg` and their dark variants are therefore **kept in
`assets/` and not published**. They are correct artwork for a strip they are
not currently in, and `ci/check-site-assets-sync.sh` reports them as unused on
every run rather than letting them become files whose status nobody knows.
Adding one of those clouds is putting its tile back.

The strip is ordered **alphabetically**, so the order carries no ranking. It
was grouped by status first, which reads as arbitrary unless you already know
the statuses.

The note that used to sit under the strip — explaining what "types only" meant
for GCP — is gone, because GCP has clients for three kinds now and the
sentence described a state that no longer holds. What replaced it is the
per-cloud tag on the tile itself and the coverage section further down, both of
which are derived from `docs/coverage.md` rather than restating it in prose
that has to be remembered separately.

### The light/dark socket

Each provider is now a **pair** of files, and the page selects between them:

    assets/providers/<name>.svg        light background
    assets/providers/<name>-dark.svg   dark background

selected with `<picture><source media="(prefers-color-scheme: dark)">`, which
needs no script and degrades to the light file in anything that does not
understand it.

Both files in each pair are still this project's own wordmarks — one with a
dark ink, one with a light one. Note what changed and what did not: they used
to be a single file relying on `currentColor` to invert, which worked and
could not accept a vendor's artwork, because a vendor's logo has its own fixed
colours and comes as two separate files. The pair *is* the socket.

**To install a vendor's real logos:** drop their own light file at
`<name>.svg` and their own dark file at `<name>-dark.svg`, then change only the
`width` and `height` in `site/index.html` to the new intrinsic size. Nothing
else in the markup or CSS needs touching.

Two rules that survive the change, and they are the whole reason this is a
socket rather than a fait accompli:

- **Use each vendor's own two files.** Do not recolour one file to produce the
  other — that is a modified mark, and it is usually the precise thing their
  guidelines prohibit. A vendor that publishes only one variant has, in
  effect, told you it should not be inverted.
- **Do not let an agent fetch them.** Logo aggregators host outdated and
  unofficial variants, and shipping one is worse than shipping no logo. Each
  file has to come from the vendor's own brand page, under its terms, fetched
  by a person who accepted them.

### If you want the official logos instead

They can go in, and it is your call rather than mine, but it is a decision to
take deliberately and the conditions differ per vendor:

| Vendor | Where the terms live |
|---|---|
| AWS | the AWS Trademark Guidelines — notably restrictive; the logo is generally not available for third-party use without a written agreement, and "Powered by AWS" badges are the sanctioned route |
| Google Cloud | Google's brand permissions, which allow some referential use of the Cloud logo under stated conditions |
| Microsoft Azure | the Microsoft Trademark and Brand Guidelines |
| OVHcloud, Scaleway | each publishes a press/brand kit |

Two practical points. Each vendor wants its *own* file, unmodified — so
recolouring five logos to a common monochrome, which is what would make the
strip look coherent, is usually the thing their guidelines prohibit. And a
vendored logo is a binary asset that has to be re-checked when they refresh
their branding, which the wordmarks never do.

To go ahead: download each from the vendor's own brand page under its terms,
drop them in `assets/providers/`, and the markup needs only the `src` and the
intrinsic `width`/`height` changed. Do not let an agent fetch them for you from
a search result — logo aggregator sites host outdated and unofficial
variants, and using one is worse than using no logo at all.

## The social card and the repository's topics

`assets/social-card.png` is a 1200x630 raster of the mark plus a line of text,
rendered from `assets/../` — the same three cube faces and the same `∃`, at
scale, with no recolouring. It is referenced by `og:image` and
`twitter:image`.

It is a **PNG on purpose**. Most crawlers do not rasterise SVG, so pointing
`og:image` at `logo.svg` is silently dropped and the link preview degrades to a
bare URL — a failure with no error anywhere. `ci/check-site-assets-sync.sh`
resolves every self-referential absolute URL in the page's metadata against the
published tree, because a social card that 404s is invisible in exactly the
same way.

To regenerate it after a change to the mark:

    rsvg-convert -w 1200 -h 630 -o assets/social-card.png <the card source>
    cp assets/social-card.png site/social-card.png

The page's `keywords` and the repository's **topics** are deliberately the same
list — `infrastructure-as-code`, `iac`, `terraform`, `opentofu`, `lean`,
`lean4`, `cloud`, `cloud-management`, `devops`, `dependent-types`, `aws`,
`gcp`, `scaleway`. The same words should find this project whether someone
searches GitHub or the web, and two lists meant to agree will drift unless
they are written down as agreeing. Topics are set through the API, not in this
repository, so this paragraph is the only record of what they are.

## Open question

There is no conventional "made with Lean" badge — Lean is not in Simple Icons,
so `shields.io?logo=lean` does not work, and neither the logos page nor
Reservoir publishes badge artwork. A badge using the *word* Lean adjectivally
is within policy; one embedding a modified Lean logo is a derived logo and is
not. Left alone for now.

## Sources

- Lean logos and downloads — <https://lean-lang.org/logos/>
- Lean trademark policy — <https://lean-lang.org/trademark-policy>
- OpenTofu brand artifacts — <https://github.com/opentofu/brand-artifacts>
- LF Projects trademark policy — <https://lfprojects.org/policies/trademark-policy/>
