# infra

Terraform/OpenTofu-style infrastructure as code, defined in Lean instead of a
bespoke DSL. Target and observed state are dependently-typed Lean values, so
an unrealisable target is a compile error rather than a runtime surprise.
Targets AWS and Scaleway today, with one portable spec usable under either
cloud — see `docs/architecture.md`.

## Build

```
lake build
lake exe infra check   # offline self-checks; no cloud, no credentials needed
```

## Running against real accounts

`infra` needs credentials for both clouds — see `docs/authentication.md` for
the config file / keychain / environment-variable chain it tries, in that
order.

```
lake exe infra check           # offline self-checks (default, no cloud)
lake exe infra pull            # observe both clouds, cache to .infra/
lake exe infra plan            # show what would change, no changes made
lake exe infra push            # same as plan — a dry run
lake exe infra push --apply    # actually reconcile
```

## Example: pulling Scaleway state alone

`example/ScalewayPull.lean` is a smaller, self-contained slice: authenticate
to **Scaleway only** (no AWS credentials read or required), pull whatever the
account reports for every `Kind`, and write it to `out/scaleway/` — once as
JSON, once as elaborable Lean source.

```
$ lake exe scaleway-pull
authenticating to Scaleway...
authenticated (region fr-par)
  object-store: 2 resource(s) -> out/scaleway/object-store.json, out/scaleway/object-store.lean
  compute: 1 resource(s) -> out/scaleway/compute.json, out/scaleway/compute.lean
done: 3 resource(s) across every kind Scaleway reported
```

Only Scaleway credentials are needed for this one — `~/.config/scw/config.yaml`,
the OS keychain, or `SCW_ACCESS_KEY`/`SCW_SECRET_KEY` (see
`docs/authentication.md`). Output lands under the gitignored `out/`, so it is
safe to inspect and delete.

## Documentation

- `docs/architecture.md` — overall design and the portability rules
- `docs/authentication.md` — where credentials come from
- `docs/persistence.md` — how observed state is cached
- `docs/providers.md` — how each `Kind` maps onto each cloud's API
- `docs/diff-semantics.md` — how target vs. observed state is compared
