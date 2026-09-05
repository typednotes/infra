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

`assets/providers/*.svg` are **wordmarks set in this project's own type**, in
`currentColor` so they invert with the theme. They are not AWS's or Scaleway's
logos, and that is deliberate: the same caution that applies to Lean and
OpenTofu applies here, and AWS's guidelines in particular are strict about
their marks.

Naming a product you interoperate with is nominative use and is ordinarily
fine; reproducing its logo is a different act. Since the page only needs to say
*which clouds this supports*, the name does the whole job and carries none of
the risk. It also happens to make the strip trivially extensible — a new cloud
is one more file with one more word in it, and the three greyed "planned" tiles
cost nothing.

If the real logos are ever wanted, both companies publish brand pages with
conditions attached, and that is a decision to make deliberately rather than by
dropping a downloaded PNG into the repo.

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
