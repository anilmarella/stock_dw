.PHONY: run_pipeline lint lint_fix

run_pipeline:
	./automation/run_pipeline.sh

lint:
	uv run sqlfluff lint transformation/models

lint_fix:
	uv run sqlfluff fix transformation/models
