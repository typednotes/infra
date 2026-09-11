# What `infra` needs to be allowed to do

Two different questions live here, and conflating them is how this repository
ended up with one document trying to be both:

| | Document | Scope |
|---|---|---|
| **What a real fleet needs** | [`aws-operator-policy.json`](aws-operator-policy.json), this page's tables | every kind the library implements, adapted to *your* account, region and naming |
| **What this repository's CI needs** | [`../ci/aws-permissions-policy.json`](../ci/aws-permissions-policy.json) | the eight kinds the live test declares, confined to `ci-tests-infra-*` in one account and one region |

The second is deliberately narrower and is **not** a starting point for the
first: every ARN in it names the live test's own prefix, which is the only
thing stopping a credential assumable from GitHub Actions from touching a real
queue. See [`ci-auth.md`](ci-auth.md) for that side.

## The shape: wide per product, narrow per resource

Both documents grant `sqs:*`, `s3:*`, `secretsmanager:*` and so on — **not** an
enumerated action list — and then confine each to `PREFIX*` ARNs. That is a
deliberate reversal of an earlier design, and the reasoning is worth keeping:

- **The resource scoping is what protects anything.** A credential holding
  `sqs:*` on `my-fleet-*` cannot touch a queue it does not own. That property
  is unchanged by widening the verbs.
- **The action enumeration protected almost nothing, and rotted constantly.**
  Every kind added to a fleet, and every new call inside a kind, meant another
  policy edit — discovered as a 403 in the middle of a run. `iam:TagUser` was
  exactly that: the ownership marker started being written at create, and a
  policy naming six IAM verbs did not include the seventh.

So the rule for adding to a fleet is now: **a new kind of an existing product
needs no policy change; a new product needs one statement.** The table below is
still the record of what is actually called — for debugging a 403, for anyone
who does want to enumerate, and because it is the only place that says
`iam:PassRole` is part of deploying a Lambda.

### Where the wildcard is not safe, and why

Three carve-outs, all visible in the documents:

- **EC2 cannot be name-scoped at all.** Its resources are ids, not names, so
  there is no `PREFIX*` to write and the grant falls back to a region
  condition. `ec2:*` in a region therefore means *every* instance, volume,
  VPC and security group in it — including production. So EC2 stays
  enumerated: it is the one product where the action list is the only limit
  there is. The statement is named `Ec2MutationsCannotBeNameScoped` to keep
  that from being tidied away later.
- **`iam:*` on a user is a path to full admin**, in three steps: create a user
  under the prefix, attach `AdministratorAccess` to it, mint an access key.
  The prefix does not help — the new user is inside it. The documents grant
  `iam:*` on `PREFIX*` users but pair it with an explicit `Deny` on every
  action that mints a usable credential (`CreateAccessKey`,
  `CreateLoginProfile`, service-specific credentials, MFA, SSH keys), on
  `Resource: "*"` so it cannot be worked around. An explicit `Deny` beats any
  `Allow`, so the escalation is closed while ordinary user management stays
  wide. The residue: the role can still attach a powerful policy to a
  credential-less user, which is untidy but not usable.
- **`iam:PassRole` stays pinned to one role**, with an `iam:PassedToService`
  condition. Passing an arbitrary role to Lambda is running code as that role,
  so this is the one grant that must never be widened to `*`.

Read-only breadth has one limit too: `ReadOnlyAndUnscopable` lists *listing*
actions, never `Get*` wildcards. `secretsmanager:Get*` or `s3:Get*` on `"*"`
would be account-wide data access, which is not what "read-only" should buy.

## The rule that catches people out: the ownership marker needs two grants

Every resource `infra` creates carries an ownership tag
(`Infra/Core/Ownership.lean`), and every kind that can carry one has it
**written at create and read back on the next `push`**. So each kind needs a
tagging permission *and* a tag-reading permission beyond its create and delete.

The two halves fail very differently:

- Missing the **write** half fails loudly, at create, naming the action —
  `is not authorized to perform: iam:TagUser`.
- Missing the **read** half fails **silently**. `readOwnership` reports `none`
  when its call fails, the engine reads that as "this cloud cannot answer"
  and falls back to the ledger, so the ownership perimeter quietly stops being
  enforced for that kind. Nothing in the output says so.

That asymmetry is why the read grants are listed here rather than left to be
discovered: a run that is missing them looks like a run that is working.

## AWS, per kind

Read off the call sites in `Infra/Providers/Kinds/` — the API each function
calls is named in the source, so this table is derivable rather than
remembered. Last checked against the code on 2026-09-11.

| Kind | Actions | Tag write / read |
|---|---|---|
| `queues` | `sqs:CreateQueue`, `DeleteQueue`, `GetQueueUrl`, `GetQueueAttributes`, `SetQueueAttributes`, `ListQueues` | `sqs:TagQueue` / `sqs:ListQueueTags` |
| `secrets` | `secretsmanager:CreateSecret`, `DeleteSecret`, `DescribeSecret`, `PutSecretValue`, `GetSecretValue`, `ListSecrets` | `secretsmanager:TagResource` / `DescribeSecret` carries them |
| `imageRegistry` | `ecr:CreateRepository`, `DeleteRepository`, `DescribeRepositories`, `PutImageTagMutability` | *none — ECR repositories are not marked* |
| `objectStore`, `s3Bucket` | `s3:CreateBucket`, `DeleteBucket`, `PutBucketVersioning`, `GetBucketVersioning`, `PutBucketObjectLockConfiguration`, `GetBucketObjectLockConfiguration`, `ListAllMyBuckets` | `s3:PutBucketTagging` / `s3:GetBucketTagging` |
| `securityGroup` | `ec2:CreateSecurityGroup`, `DeleteSecurityGroup`, `AuthorizeSecurityGroupIngress`, `DescribeSecurityGroups` | `ec2:CreateTags` / `DescribeSecurityGroups` carries them |
| `awsInstance` | `ec2:RunInstances`, `TerminateInstances`, `ModifyInstanceAttribute`, `DescribeInstances`, `DescribeImages` | `ec2:CreateTags` / `DescribeInstances` carries them |
| `iam` | `iam:CreateUser`, `DeleteUser`, `ListUsers`, `ListAttachedUserPolicies`, `AttachUserPolicy`, `DetachUserPolicy` | `iam:TagUser` / `iam:ListUserTags` |
| `compute` | `lambda:CreateFunction`, `DeleteFunction`, `GetFunction`, `ListFunctions`, `UpdateFunctionCode`, `UpdateFunctionConfiguration`, **plus `iam:PassRole`** on the execution role | `lambda:TagResource` / `GetFunction` carries them |
| `postgres` | `rds:CreateDBInstance`, `DeleteDBInstance`, `ModifyDBInstance`, `DescribeDBInstances` | `rds:AddTagsToResource` / `rds:ListTagsForResource` |

`sts:GetCallerIdentity` is called before anything else, to refuse to act
against the wrong account (`Infra/Providers/Kinds/Identity.lean`). It needs no
permission — AWS always allows it — which is precisely why that call was chosen
for the check.

`iam:PassRole` on the `compute` row is the one that is not a Lambda permission
at all. Creating a function hands it an execution role, and AWS treats that as
passing a role, so a policy with every `lambda:*` action and no `PassRole`
still cannot create a function. Scope it to the execution role you actually
use, with an `iam:PassedToService` condition — the template does.

### Two rows nothing verifies

**`compute` (Lambda) and `postgres` (RDS) are not in any live test.** Lambda
needs an ECR image to exist first, and RDS takes longer to create than the
workflow's step timeout, so both are deliberately out of `test/Live.lean`'s
fleets. Their rows above are read from the code and have **never been checked
against a real 403**, unlike the other seven, which a live run exercises every
time it passes.

Treat them as a good first guess rather than as verified fact, and expect one
more permission to surface the first time someone runs them for real —
container-image Lambdas in particular may need ECR read actions on the calling
side, which no code path in this repository has yet proven either way. If you
find out, correct this table; that is what it is for.

The statement Sids in the template say the same thing —
`FunctionsNotExercisedByCi`, `DatabasesNotExercisedByCi`,
`FunctionExecutionRoleNotExercisedByCi` — so the caveat travels with the
document rather than staying on this page.

The per-product wildcards blunt this: `lambda:*` covers whatever Lambda call
the first real run turns out to need, so the likely surprise is a permission
in a *different* product — ECR reads for a container image, KMS for an
encrypted database — rather than a missing Lambda verb.

## Using the template

[`aws-operator-policy.json`](aws-operator-policy.json) is the table above as an
IAM document, with three placeholders to replace and nothing else:

| Placeholder | Meaning |
|---|---|
| `ACCOUNT` | your twelve-digit account id |
| `REGION` | the region your fleet is placed in — the one `Infra/Core/Region.lean` maps your locality to |
| `PREFIX` | the name prefix your resources share, so the grant cannot reach anything else. Drop the `PREFIX*` and leave `*` if your fleet's names have nothing in common — but then the policy confines nothing |

```sh
sed -e 's/ACCOUNT/123456789012/g' \
    -e 's/REGION/eu-west-1/g' \
    -e 's/PREFIX/my-fleet-/g' \
    -e 's/EXECUTION-ROLE-NAME/my-lambda-role/g' \
    docs/aws-operator-policy.json > /tmp/infra-operator.json

./ci/check-aws-policy.py            # grammar, offline — checks both documents

aws accessanalyzer validate-policy \
  --policy-document file:///tmp/infra-operator.json \
  --policy-type IDENTITY_POLICY     # AWS's own validator
```

A fleet that declares only some kinds needs only those statements. Deleting the
ones you do not use is the point of them being separate statements with names —
and with the per-product shape, that is now the *only* editing a fleet's
evolution should ever need.

## GCP and Scaleway

Neither cloud takes a policy *document*, so there is no equivalent file: GCP
grants predefined roles and Scaleway grants permission sets, both as CLI
arguments. Both are far coarser than the AWS table — a role like
`roles/storage.admin` is project-wide, and Scaleway's sets are one per product
family — so there is no per-kind scoping to write down, only a per-kind role.

The mapping for both, along with the GCP services that must be *enabled* before
any role matters, is in [`../ci/README.md`](../ci/README.md). It is written
there for CI's identity, but the role and permission-set names are the same
ones a real fleet needs; only the scope (`--project`, `project-ids`) differs.

Two GCP facts worth repeating here because they cost time:

- **Enabling an API and granting a role are separate acts**, and a disabled API
  fails with `PERMISSION_DENIED … has not been used in project … or it is
  disabled`, which reads exactly like a missing role and is not one.
- **Deploying Cloud Run as an identity needs `iam.serviceAccounts.actAs` on
  that identity**, which `roles/run.admin` does not imply.
