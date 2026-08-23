-- This module serves as the root of the `Infra` library.
-- Import modules here that should be built as part of the library.

-- Core, bottom-up: the two axes, then specs, then fleets, then the engine.
import Infra.Core.Finite
import Infra.Core.Refine
import Infra.Core.Kind
import Infra.Core.Expr
import Infra.Core.Spec
import Infra.Specs.Basic
import Infra.Core.Fleet
import Infra.Core.Action
import Infra.Core.Backend
import Infra.Core.Persistence
import Infra.Core.Engine

-- Authentication is orthogonal to the resource theory above.
import Infra.Core.Auth
import Infra.Abstractions.Auth

-- One backend per cloud.
import Infra.Providers
import Infra.Demo
