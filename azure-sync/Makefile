# Makefile for Azure FreeIPA Sync

.PHONY: help install uninstall test validate monitor clean

# Default target
help:
	@echo "Azure FreeIPA Sync - Available Commands:"
	@echo ""
	@echo "  make install    - Install the sync tool (requires root)"
	@echo "  make uninstall  - Uninstall the sync tool (requires root)" 
	@echo "  make test       - Test configuration and run dry-run"
	@echo "  make validate   - Validate configuration only"
	@echo "  make monitor    - Show sync status and logs"
	@echo "  make clean      - Clean temporary files"
	@echo ""
	@echo "Manual Installation:"
	@echo "  sudo ./scripts/install.sh"
	@echo ""

install:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: Installation requires root privileges"; \
		echo "Please run: sudo make install"; \
		exit 1; \
	fi
	@chmod +x scripts/install.sh
	@./scripts/install.sh

uninstall:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: Uninstallation requires root privileges"; \
		echo "Please run: sudo make uninstall"; \
		exit 1; \
	fi
	@chmod +x scripts/uninstall.sh
	@./scripts/uninstall.sh

test:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: Testing requires root privileges"; \
		echo "Please run: sudo make test"; \
		exit 1; \
	fi
	@if [ -f /opt/freeipa-sync/test_sync.sh ]; then \
		/opt/freeipa-sync/test_sync.sh; \
	else \
		echo "Sync tool not installed. Run 'make install' first."; \
	fi

validate:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: Validation requires root privileges"; \
		echo "Please run: sudo make validate"; \
		exit 1; \
	fi
	@if [ -f /opt/freeipa-sync/validate_config.py ]; then \
		python3 /opt/freeipa-sync/validate_config.py; \
	else \
		echo "Sync tool not installed. Run 'make install' first."; \
	fi

monitor:
	@if [ -x /usr/local/bin/azure-sync-monitor ]; then \
		azure-sync-monitor; \
	elif [ -f /opt/freeipa-sync/monitor.sh ]; then \
		/opt/freeipa-sync/monitor.sh; \
	else \
		echo "Monitor tool not available. Run 'make install' first."; \
	fi

clean:
	@echo "Cleaning temporary files..."
	@find . -name "*.pyc" -delete
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Clean completed."

# Development targets (for maintainers)
.PHONY: dev-setup dev-lint dev-test

dev-setup:
	@echo "Setting up development environment..."
	@pip3 install -r requirements.txt
	@pip3 install flake8 black pylint
	@echo "Development setup complete."

dev-lint:
	@echo "Running code quality checks..."
	@flake8 src/ --max-line-length=120
	@black --check src/
	@pylint src/

dev-test:
	@echo "Running development tests..."
	@python3 -m pytest tests/ || echo "No tests found - create tests/ directory with test files"