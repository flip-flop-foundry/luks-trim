.PHONY: gha-inspect gha-rerun gha-watch gha-follow

gha-inspect:
	./scripts/gha-loop.sh "Integration Tests" inspect

gha-rerun:
	./scripts/gha-loop.sh "Integration Tests" rerun-failed

gha-watch:
	./scripts/gha-loop.sh "Integration Tests" watch-latest

gha-follow:
	./scripts/gha-loop.sh "Integration Tests" watch-latest
