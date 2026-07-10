# API_KEYS

## Overview

Build Pilot is intended to be local-first for V1. That means the initial version should not depend on a cloud-hosted production stack or a large number of external service credentials.

## Current Position

- No production API keys are required for the initial local prototype.
- Optional AI providers may be used later for transcription, summarization, or estimation support.
- Any future provider integration should be implemented through a modular abstraction so the system can swap providers without changing the core workflow.

## Recommended Practice

If an external AI provider is introduced in a later phase:
- store secrets in local environment files only
- never commit keys to the repository
- keep provider-specific configuration isolated from core application logic
- document required variables clearly in the local setup process

## Suggested Environment Variables

The following names are proposed for future use:
- OPENAI_API_KEY
- ANTHROPIC_API_KEY
- AI_PROVIDER
- AI_MODEL

These values should be kept out of source control and should only be used in local development until the product is ready for a more formal deployment approach.

## Security Notes

- Do not hard-code API keys into source files.
- Use local environment files or secure developer key storage.
- Review any future cloud integrations carefully before enabling them in shared environments.
