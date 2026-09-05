-- This module serves as the root of the `Infra` library.
-- Import modules here that should be built as part of the library.

-- Core, bottom-up: the two axes, then specs, then fleets, then the engine.
import Infra.Core.Finite
import Infra.Core.Ansi
import Infra.Core.Refine
import Infra.Core.Kind
import Infra.Core.Expr
import Infra.Core.Spec
import Infra.Core.Coe
import Infra.Core.InstanceType
import Infra.Core.Compose
import Infra.Specs.Basic
import Infra.Specs.Build
import Infra.Core.Fleet
import Infra.Core.Ergonomics
import Infra.Core.Region
import Infra.Core.Declare
import Infra.Core.Action
import Infra.Core.Backend
import Infra.Core.Diverge
import Infra.Core.Settle
import Infra.Core.Credentials
import Infra.Core.Persistence
import Infra.Core.Engine

-- Authentication is orthogonal to the resource theory above.
import Infra.Core.Auth
import Infra.Abstractions.Auth

-- One backend per cloud.
import Infra.Providers.JsonRead
import Infra.Providers.Http
import Infra.Providers.Aws.Sign
import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Providers.Kinds.ObjectStore
import Infra.Providers.Kinds.Queues
import Infra.Providers.Kinds.ImageRegistry
import Infra.Providers.Kinds.Secrets
import Infra.Providers.Kinds.Compute
import Infra.Providers.Kinds.Iam
import Infra.Providers.Kinds.Postgres
import Infra.Providers.Kinds.Ec2
import Infra.Providers.Kinds.Identity
import Infra.Providers.Live
import Infra.Providers

-- Interoperability with the tool this replaces, both directions.
import Infra.Interop.Terraform

-- The command-line front end, so a declaration repo's `Main` is a call rather
-- than a copy of the dispatch.
import Infra.Cli

import Infra.Demo
