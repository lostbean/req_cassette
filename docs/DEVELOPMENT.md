# Development Guide

This document provides information for developers working on ReqCassette.

## Setup

1. Clone the repository
2. Install dependencies:
   ```bash
   mix deps.get
   ```

3. Compile the project:
   ```bash
   mix compile
   ```

## Code Quality Tools

### Mix Aliases

We provide two main aliases for ensuring code quality:

#### `mix precommit`

Run this before committing your code. It will:

1. **Format code** - Automatically fixes formatting issues
2. **Run Credo** - Checks code quality with strict mode
3. **Run tests** - Ensures all tests pass

```bash
mix precommit
```

This alias applies formatting changes, so your code will be modified if there
are formatting issues.

#### `mix ci`

This is designed for Continuous Integration environments. It will:

1. **Check formatting** - Fails if code is not formatted (doesn't modify files)
2. **Run Credo** - Checks code quality with strict mode
3. **Run tests** - Ensures all tests pass

```bash
mix ci
```

This alias does NOT modify your code - it only checks and will fail if
formatting is incorrect.

### Credo Configuration

Credo is configured in `.credo.exs`. Current settings:

- **Strict mode enabled** - More rigorous checks
- **Line length**: 120 characters max (low priority)
- **Module docs**: Disabled (not required for now)
- **Specs**: Disabled (not required for now)
- **Max complexity**: 12
- **Max nesting**: 3

You can run Credo separately:

```bash
# Check for issues
mix credo

# Strict mode
mix credo --strict

# Explain a specific issue
mix credo explain lib/req_cassette/plug.ex:177:7
```

### Formatter

The project uses Elixir's built-in formatter. Configuration is in
`.formatter.exs`.

Run formatter:

```bash
# Apply formatting
mix format

# Check without modifying
mix format --check-formatted
```

## Testing

### Run All Tests

```bash
mix test
```

### Run Specific Test File

```bash
mix test test/req_cassette/plug_test.exs
```

### Run Specific Test

```bash
mix test test/req_cassette/plug_test.exs:14
```

### Run Tests with Trace

```bash
mix test --trace
```

### Run LLM Tests

Some tests require API keys and are skipped by default:

```bash
# Run all tests including skipped ones
ANTHROPIC_API_KEY=sk-... mix test --include req_llm
```

## Demo Scripts

```bash
# HTTP demo (uses httpbin.org)
mix run examples/httpbin_demo.exs

# ReqLLM demo (requires API key)
ANTHROPIC_API_KEY=sk-... mix run examples/req_llm_demo.exs
```

## Workflow

### Before Committing

Always run `mix precommit` before committing:

```bash
# Make your changes
# ...

# Run precommit (formats, checks, tests)
mix precommit

# Commit your changes
git add .
git commit -m "Your message"
```

### In CI/CD

Your CI pipeline should run `mix ci`:

```yaml
# Example GitHub Actions
- name: Check code quality
  run: mix ci
```

The difference between `precommit` and `ci`:

- **precommit**: Fixes formatting automatically (for local development)
- **ci**: Only checks formatting, fails if not formatted (for CI/CD)

## Common Credo Issues

### Nested Modules (AliasUsage)

```elixir
# Instead of:
Plug.Conn.put_resp_header(conn, "foo", "bar")

# Consider aliasing at the top:
alias Plug.Conn

Conn.put_resp_header(conn, "foo", "bar")
```

This is currently set to `:low` priority and won't fail the build.

## Dependencies

Core dependencies:

- `req` - HTTP client
- `plug` - Web library (for connection handling)
- `jason` - JSON encoding/decoding
- `req_llm` - LLM integration

Dev/Test dependencies:

- `bypass` - Mock HTTP server for testing
- `credo` - Code quality checker

## Documentation

- `README.md` - Project overview and quick start
- `SUMMARY.md` - Complete project documentation
- `docs/guides/` - User guides (templating, ReqLLM, filtering)
- `DEVELOPMENT.md` - This file

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `mix precommit` to ensure quality
5. Submit a pull request

## Troubleshooting

### Tests failing in wrong environment

If you see "mix test is running in the dev environment", make sure you're using
the aliases:

```bash
# ❌ Wrong
mix test

# ✅ Correct
mix precommit
# or
mix ci
```

The aliases are configured with `preferred_cli_env` to run in the test
environment.

### Credo too strict

If Credo is flagging too many issues, you can adjust `.credo.exs`:

```elixir
# Disable a specific check
{Credo.Check.Readability.ModuleDoc, false}

# Lower priority
{Credo.Check.Design.AliasUsage, priority: :low, exit_status: 0}
```

### Format check failing in CI

Make sure you ran `mix format` locally before pushing:

```bash
mix format
git add .
git commit -m "Format code"
git push
```
