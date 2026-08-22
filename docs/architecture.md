# Architecture

## General goal

The goal of this project is to enable the definition of remote architectures within Lean, like Terraform/OpenTofu.
Objects are defined in Lean leveraging dependent types so that it should be impossible to define impossible states or target states.
Remote state, remote objects can be pulled from the remote service they live in.
A target state can be defined, to set the desired state of the remote system.
An engine can call the remote service to sync the current state and implement the target.
To implement a target, objects defining states should allow state diffs.

## Remote services

To start, we will target the following remote cloud providers:
- AWS: https://aws.amazon.com/
- Scaleway: https://www.scaleway.com/

Later we will support other clouds:
- GCP: 
- Azure: 
- OVH: 

## Coverage

We will start with the basic services:
- IAM
- Object store
- Compute
- Queues
- Secrets
- Image registry

With an emphasis on
- Serverless compute
- Serverless db
- Object store
- AI model

And on what's common to AWS and Scaleway

## Abstractions

Each service is defined in details: each service lives in its own module.
But common concepts across services are abstracted:
- Authentification
- Secret management
- Object store
- Serverless Postgres
- Serverless compute

These concepts can be manipulated and implemented across various backends.

It should still be possible to manipulate lower level concepts, closer to the service provider.

## Basic local system services

Basic file manipulation, network, and other IO use:
- Lean standard lib
- and the latest release of Linen: https://github.com/typednotes/linen

## Definitions

There are 2 kinds of objects:
- Objects to define the current state of a remote system and cache it on disk
- Objects to define a target state

The idea is that each remote object can be defined locally in lean.
Each lean state object definition can be persisted locally.
A target state can be defined in a Lean source code and this code can be versioned in git.
Dependent types should be used wherever possible to make impossible states or target states non-representable.
Object defining the remote state or the state target can be diffed so the controller can use the diff to move to target.

## Inspirations

Terraform/OpenTofu are sources of inspiration to the extend they don't use dependent types in their declaration language.

## Authentication

Basic authentication to a service happens by opening the browser.
Later, other means of authentication will be used.