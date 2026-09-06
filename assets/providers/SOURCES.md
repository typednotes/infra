# Where each provider mark came from

Recorded per file, because provenance is the thing that decays first: a logo
that was correct when added stays in the repository long after the vendor has
refreshed its branding, and without a source and a date nobody can tell
whether it is current.

`docs/branding.md` is the policy. This is the ledger.

## The vendors' own marks

Installed **byte-identical to what was downloaded** — no recolouring, no
re-scaling, no re-export, not even an added XML comment. That is deliberate:
each vendor's guidelines ask for its own file unmodified, and a provenance note
inside the file would be a modification for no benefit that this file cannot
give instead.

| File | Source page | Direct file | Fetched |
|---|---|---|---|
| `aws.svg` | [fr.wikipedia `Fichier:Amazon_Web_Services_Logo.svg`](https://fr.wikipedia.org/wiki/Fichier:Amazon_Web_Services_Logo.svg) | `upload.wikimedia.org/wikipedia/commons/9/93/Amazon_Web_Services_Logo.svg` | 2026-09-06 |
| `gcp.svg` | [Commons `File:Google_Cloud_logo.svg`](https://commons.wikimedia.org/wiki/File:Google_Cloud_logo.svg) | `upload.wikimedia.org/wikipedia/commons/5/51/Google_Cloud_logo.svg` | 2026-09-06 |
| `scaleway.svg` | [fr.wikipedia `Fichier:ScalewayLogo.svg`](https://fr.wikipedia.org/wiki/Fichier:ScalewayLogo.svg) | `upload.wikimedia.org/wikipedia/fr/a/a3/ScalewayLogo.svg` | 2026-09-06 |

What the hosts state about each, read from the MediaWiki `imageinfo` API
rather than from the rendered page:

| File | Author | Copyright | Restriction |
|---|---|---|---|
| `aws.svg` | Amazon.com Inc. | Apache License 2.0 | **trademarked** |
| `gcp.svg` | Google | Public domain | **trademarked** |
| `scaleway.svg` | Scaleway | *marque déposée* (non-free tag) | **trademarked** |

Three things in that table matter more than they look.

**Every one is marked `trademarked`, and the copyright licence does not touch
that.** Apache-2.0 §6 declines to grant trademark rights in as many words, and
a public-domain dedication of the *file* says nothing about the *mark*. This is
the same distinction `docs/branding.md` already draws for OpenTofu, where
MPL-2.0 §1.9 does the same job. So the licence column is not permission to use
the logo; it is only permission to copy the file.

**`scaleway.svg` is hosted on fr.wikipedia rather than Commons**, under a
non-free trademark tag. That means Wikipedia is relying on a doctrine that
applies to Wikipedia, and does not extend to anyone who copies the file.

**None of the three is the vendor's own brand page.** `docs/branding.md` asks
for exactly that and warns against third-party hosts, because they carry
outdated and unofficial variants. These were checked on arrival — no scripts,
no external references, and the colours are each vendor's real ones
(`#252F3E`/`#FF9900`, Google's four plus `#5f6368`, `#521094`) — so they are
not *wrong*. They are simply not authoritative, and a vendor refresh will not
reach them.

Installed at the repository owner's explicit direction, with the above known.

## This project's own wordmarks

`azure.svg`, `azure-dark.svg`, `ovh.svg`, `ovh-dark.svg` are **not** those
companies' logos. They are the provider's *name*, set in this project's type,
as a light/dark pair. Nominative use of a name is a different act from
reproducing a mark, and for a strip whose whole job is to say which clouds are
supported, the name does the work at none of the risk. Replace them the day
their official files are obtained under their own terms.
