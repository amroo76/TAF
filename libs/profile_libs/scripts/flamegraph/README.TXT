FlameGraph Toolkit Integration
==============================

This directory contains the minimal set of scripts from the FlameGraph
project required for TAF to generate flamegraph SVGs from perf data.

Included scripts:
  - stackcollapse-perf.pl
  - flamegraph.pl

These scripts are authored by Brendan Gregg and are available under the
CDDL license. The original project and full toolkit can be found at:

  https://github.com/brendangregg/FlameGraph

Only the two scripts above are required for TAF profiling. They convert
raw 'perf script' output into folded stacks and then into an SVG flamegraph.

TAF integration:
  perf_runner.py writes flamegraph.txt (raw perf script output)
  TAF then runs:
    stackcollapse-perf.pl flamegraph.txt > flamegraph.folded
    flamegraph.pl flamegraph.folded > flamegraph.svg

The resulting flamegraph.svg is written into the profiler results
directory for each iteration when --profiler-generate-flamegraph is set.
