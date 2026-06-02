# ----------------------------------------------------------------------------
# Makefile for ubuntu-benchmark — ergonomic wrappers around ./sysbench.sh
#
# This does not reimplement anything; it turns the script's common flag
# combinations into short targets and maps a few make variables onto flags.
# Unset variables fall through to the script's own defaults.
#
# Usage:
#   make                               # show this help (default goal)
#   make bench                         # full run (info, cpu, mem, disk, gpu)
#   make cpu                           # run only the CPU section
#   make disk DIR=/data SIZE=4096      # disk test, custom dir + file size
#   make bench RUNS=5 JSON=out.json    # averaged full run, also write JSON
#   make net HOST=10.0.0.2             # network test against an iperf3 -s host
#   make quick                         # the fast sections only (cpu + mem)
#   make clean                         # remove stray result/test files
#
# Variables (override on the command line, e.g. `make disk SIZE=2048`):
#   DIR   disk test directory          (script default: .)
#   SIZE  disk test file size in MB    (script default: 1024)
#   RUNS  repeat each measurement N×   (script default: 1)
#   HOST  iperf3 -s server for `net`   (required by the `net` target)
#   JSON  also write JSON to this file (off by default)
#   ARGS  extra raw flags appended to every run (escape hatch)
# ----------------------------------------------------------------------------

SCRIPT := ./sysbench.sh

# Variables -> flags: each expands to nothing unless the variable is set, so
# unset variables leave the script on its own defaults (no drift).
DIR_FLAG  := $(if $(DIR),--dir $(DIR),)
SIZE_FLAG := $(if $(SIZE),--size $(SIZE),)
RUNS_FLAG := $(if $(RUNS),--runs $(RUNS),)
JSON_FLAG := $(if $(JSON),--json $(JSON),)

# Flags that apply regardless of section (so they work on every target).
COMMON := $(RUNS_FLAG) $(JSON_FLAG) $(ARGS)

.DEFAULT_GOAL := help
.PHONY: help bench all cpu mem disk gpu net quick json clean deps

help: ## Show this help
	@echo 'ubuntu-benchmark — make targets:'
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo 'Variables: DIR SIZE RUNS HOST JSON ARGS   (e.g. make disk DIR=/data SIZE=4096)'

bench: ## Full run: info, cpu, mem, disk, gpu (no net)
	$(SCRIPT) $(DIR_FLAG) $(SIZE_FLAG) $(COMMON)

all: bench ## Alias for `bench`

cpu: ## CPU benchmark only
	$(SCRIPT) --cpu $(COMMON)

mem: ## Memory benchmark only
	$(SCRIPT) --mem $(COMMON)

disk: ## Disk I/O benchmark only (honors DIR, SIZE)
	$(SCRIPT) --disk $(DIR_FLAG) $(SIZE_FLAG) $(COMMON)

gpu: ## GPU benchmark only (NVIDIA)
	$(SCRIPT) --gpu $(COMMON)

quick: ## Fast sections only: cpu + mem
	$(SCRIPT) --cpu --mem $(COMMON)

net: ## Network test (requires HOST=<iperf3 -s host>)
	@: $(if $(HOST),,$(error HOST is required: make net HOST=<iperf3 -s host>))
	$(SCRIPT) --iperf-host $(HOST) $(COMMON)

json: ## Full run, writing JSON (defaults JSON=results.json)
	$(SCRIPT) $(DIR_FLAG) $(SIZE_FLAG) $(RUNS_FLAG) --json $(or $(JSON),results.json) $(ARGS)

clean: ## Remove stray benchmark test/result files (current dir)
	rm -f fio.?????? .sysbench_dd_* results.json
	@echo 'cleaned stray fio/dd test files and results.json'

deps: ## Show the apt command to install the high-fidelity tools (does NOT run it)
	@echo 'These tools improve fidelity. Run this yourself (needs sudo):'
	@echo '  sudo apt install sysbench fio iperf3'
