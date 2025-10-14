# Contributing to Azure FreeIPA Sync

Thank you for your interest in contributing to the Azure FreeIPA Sync project! This document provides guidelines and information for contributors.

## Development Setup

### Prerequisites

- Rocky Linux 9 (recommended for testing)
- Python 3.9 or later
- FreeIPA server (for testing)
- Azure Entra ID tenant (for testing)
- Git

### Setting Up Development Environment

1. **Clone the repository:**
   ```bash
   git clone https://github.com/creeksidenetworks/freeIPA.git
   cd freeIPA
   ```

2. **Set up development environment:**
   ```bash
   make dev-setup
   ```

3. **Create a test configuration:**
   ```bash
   cp config/azure_sync.conf.example dev-config/test.conf
   # Edit dev-config/test.conf with your test environment details
   ```

## Project Structure

```
freeIPA/
├── src/                              # Main source code
│   ├── azure_freeipa_sync.py         # Core sync logic
│   └── validate_config.py            # Configuration validation
├── scripts/                          # Installation and utility scripts
│   ├── install.sh                    # Installation script
│   ├── uninstall.sh                  # Uninstall script
│   └── monitor.sh                    # Monitoring utilities
├── config/                           # Configuration templates
│   ├── azure_sync.conf.example       # Template configuration
│   └── systemd/                      # Service definitions
├── docs/                             # Additional documentation
├── tests/                            # Test files (create as needed)
└── Makefile                          # Build and development tasks
```

## Code Style Guidelines

### Python Code Style

- Follow PEP 8 style guidelines
- Use type hints where appropriate
- Maximum line length: 120 characters
- Use meaningful variable and function names
- Add docstrings to all functions and classes

### Shell Script Style

- Use `#!/bin/bash` shebang
- Enable strict mode: `set -e`
- Use meaningful variable names in UPPER_CASE
- Add comments for complex logic
- Quote variables to prevent word splitting

### Code Quality Tools

Run code quality checks before submitting:

```bash
make dev-lint
```

This runs:
- `flake8` for style checking
- `black` for code formatting
- `pylint` for code analysis

## Testing

### Local Testing

1. **Validate code style:**
   ```bash
   make dev-lint
   ```

2. **Test configuration validation:**
   ```bash
   sudo python3 src/validate_config.py -c dev-config/test.conf
   ```

3. **Test dry run sync:**
   ```bash
   sudo python3 src/azure_freeipa_sync.py -c dev-config/test.conf --dry-run
   ```

### Integration Testing

For full integration testing, you'll need:
- Running FreeIPA server
- Azure Entra ID tenant with test app registration
- Test users and groups in Azure

## Submission Guidelines

### Before Submitting

1. **Test your changes thoroughly:**
   - Run code quality checks
   - Test with dry-run mode
   - Test actual sync operations (if possible)
   - Verify installation/uninstall scripts work

2. **Update documentation:**
   - Update README.md if adding new features
   - Update SETUP.md for installation changes
   - Add comments for complex code

3. **Check compatibility:**
   - Ensure compatibility with Rocky Linux 9
   - Test with different Python versions (3.9+)
   - Verify FreeIPA integration still works

### Pull Request Process

1. **Create a feature branch:**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes and commit:**
   ```bash
   git add .
   git commit -m "Add: description of your changes"
   ```

3. **Push to your fork:**
   ```bash
   git push origin feature/your-feature-name
   ```

4. **Create a pull request:**
   - Provide a clear description of changes
   - Reference any related issues
   - Include test results if applicable

### Commit Message Format

Use clear, descriptive commit messages:

```
Type: Brief description

Longer description if needed explaining what and why.

Examples:
- Add: new configuration validation feature
- Fix: user creation error handling
- Update: installation script for new directory structure
- Docs: improve setup instructions
```

## Issue Reporting

When reporting issues, please include:

1. **Environment information:**
   - Operating system and version
   - Python version
   - FreeIPA version
   - Azure Entra ID configuration (no secrets!)

2. **Steps to reproduce:**
   - Configuration used (sanitized)
   - Commands run
   - Expected vs actual behavior

3. **Log outputs:**
   - Relevant log entries (sanitize any secrets)
   - Error messages
   - Stack traces

4. **Additional context:**
   - Any workarounds found
   - Related issues or documentation

## Feature Requests

For feature requests, please provide:

1. **Use case description:**
   - What problem does this solve?
   - Who would benefit from this feature?

2. **Proposed solution:**
   - How should the feature work?
   - Any configuration changes needed?

3. **Alternatives considered:**
   - Other solutions you've considered
   - Why this approach is preferred

## Security Considerations

When contributing, keep in mind:

1. **Never commit secrets:**
   - Use example/template files for configuration
   - Sanitize all logs and examples

2. **Follow security best practices:**
   - Secure password generation
   - Proper file permissions
   - Input validation and sanitization

3. **Consider impact:**
   - How might changes affect security?
   - Are there new attack vectors?

## Getting Help

- **Documentation:** Check README.md and SETUP.md first
- **Issues:** Search existing issues before creating new ones
- **Discussions:** Use GitHub discussions for questions
- **Security:** Report security issues privately

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.

## Recognition

Contributors will be acknowledged in the project documentation and release notes. Thank you for helping improve Azure FreeIPA Sync!