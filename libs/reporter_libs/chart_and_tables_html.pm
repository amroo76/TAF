package reporter_libs::chart_and_tables_html;
#############################################################################
# reporter_libs::chart_and_tables_html
#
# Created: November 2025
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Generate HTML benchmark reports containing both a Chart.js visualization
#     and detailed statistical tables. This reporter consumes normalized result
#     entries produced by TAF::Reports and renders:
#         - multi-dataset line or bar charts
#         - per-thread statistical summaries
#         - iteration-level values
#         - optional diff columns for two-dataset comparisons
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Acts as the primary "comparison-grade" HTML reporter for workloads
#       that expose a primary metric across multiple thread counts.
#     - Provides extended statistics (mean, min, max, stddev, cov, percentiles,
#       skewness, kurtosis) for each dataset and thread count.
#     - Normalizes heterogeneous datasets into a unified structure suitable
#       for charting and tabular comparison.
#     - Produces deterministic, contributor-proof HTML output that requires
#       no external assets beyond the Chart.js CDN.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not validate semantic correctness of metrics or metadata.
#     - Does not compute cross-thread comparisons beyond simple diffs.
#     - Does not infer missing metadata fields.
#     - Does not modify result directories or archive output.
#     - Does not perform dynamic plugin dispatch or guess dataset identity.
#     - Does not generate JSON, text, or non-HTML formats.
#
# CONTRACT:
#     - Caller must invoke:
#           GenerateResults($resultsRef, $filename, $outputDir)
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metadata => hashref of lowercase metadata fields
#           metrics  => arrayref of metric hashes
#     - The plugin must write exactly one HTML file:
#           $outputDir/$filename.chartplus.html
#     - Primary metric must be marked with type => 'primary'.
#
# GUARANTEES:
#     - Output is deterministic and stable for diffing.
#     - Missing or malformed metrics are skipped explicitly.
#     - Extended statistics are computed using contributor-proof formulas.
#     - Chart.js is loaded from CDN for portability.
#     - HTML is self-contained and requires no TAF assets at runtime.
#     - Diff column appears only when exactly two datasets exist.
#
# NOTES:
#     - This reporter is intended for multi-dataset comparisons where the
#       primary metric varies by thread count.
#     - All statistical computations are performed directly on numeric values
#       extracted from the metrics array.
#     - Any change to metric structure or metadata expectations must be
#       reflected here and in the TAF documentation.
#############################################################################
use strict;
use warnings;
use Exporter 'import';
use File::Spec;
use List::Util qw(sum min max);

our @EXPORT_OK = qw(GenerateResults);

#############################################################################
# TAF EXTENDED STATISTICS HELPERS
#
# These routines provide deterministic, contributor-proof statistical
# primitives used by chart_and_tables_html. They operate only on numeric
# arrays and never modify caller data structures.
#############################################################################

# ---------------------------------------------------------------------------
# percentile()
#
# PURPOSE:
#     Compute an interpolated percentile value from a numeric array.
#
# ARCHITECTURAL ROLE:
#     - Provides the percentile primitive for extended statistics tables.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric ranges.
#     - Does not handle non-numeric values.
#     - Does not compute weighted percentiles.
#
# CONTRACT:
#     - $vals_ref must be an arrayref of numeric scalars.
#     - $p must be between 0 and 100.
#
# GUARANTEES:
#     - Returns 0 for empty arrays.
#     - Uses linear interpolation between adjacent ranks.
# ---------------------------------------------------------------------------
sub percentile {
    my ($vals_ref, $p) = @_;
    my @sorted = sort { $a <=> $b } @$vals_ref;
    return 0 unless @sorted;
    my $rank = ($p/100) * (@sorted - 1);
    my $lower = int($rank);
    my $upper = $lower + 1;
    my $weight = $rank - $lower;
    return $sorted[$lower] + $weight * ($sorted[$upper] - $sorted[$lower]);
}

# ---------------------------------------------------------------------------
# skewness()
#
# PURPOSE:
#     Compute the statistical skewness of a numeric dataset.
#
# ARCHITECTURAL ROLE:
#     - Supports asymmetry analysis in extended statistics tables.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric values.
#     - Does not handle zero-variance datasets (returns 0).
#
# CONTRACT:
#     - $vals_ref must be an arrayref of numeric scalars.
#     - $mean and $std must be precomputed by the caller.
#
# GUARANTEES:
#     - Returns 0 when standard deviation is zero.
# ---------------------------------------------------------------------------
sub skewness {
    my ($vals_ref, $mean, $std) = @_;
    return 0 if $std == 0;
    my $n = scalar @$vals_ref;
    my $sum = 0;
    $sum += (($_ - $mean)**3) for @$vals_ref;
    return ($sum / $n) / ($std**3);
}

# ---------------------------------------------------------------------------
# kurtosis()
#
# PURPOSE:
#     Compute the statistical kurtosis of a numeric dataset.
#
# ARCHITECTURAL ROLE:
#     - Supports tail-heaviness analysis in extended statistics tables.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric values.
#     - Does not handle zero-variance datasets (returns 0).
#
# CONTRACT:
#     - $vals_ref must be an arrayref of numeric scalars.
#     - $mean and $std must be precomputed by the caller.
#
# GUARANTEES:
#     - Returns 0 when standard deviation is zero.
# ---------------------------------------------------------------------------
sub kurtosis {
    my ($vals_ref, $mean, $std) = @_;
    return 0 if $std == 0;
    my $n = scalar @$vals_ref;
    my $sum = 0;
    $sum += (($_ - $mean)**4) for @$vals_ref;
    return ($sum / $n) / ($std**4);
}

# ---------------------------------------------------------------------------
# diff_val()
#
# PURPOSE:
#     Compute a simple difference between two numeric values and return it
#     formatted to two decimal places.
#
# ARCHITECTURAL ROLE:
#     - Supports two-dataset comparison tables in HTML reporters.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric input.
#     - Does not compute percentage differences.
#
# CONTRACT:
#     - $a and $b must be numeric scalars.
#
# GUARANTEES:
#     - Always returns a string formatted to two decimal places.
# ---------------------------------------------------------------------------
sub diff_val {
    my ($a, $b) = @_;
    return sprintf("%.2f", $b - $a);
}

#-----------------------------------------------------------------------------
# TAF BLOCK: GenerateResults() Entry Point
#
# PURPOSE:
#     Orchestrate the full HTML report generation process for multi-dataset
#     benchmark comparisons. This includes:
#         - metadata extraction
#         - dataset normalization
#         - per-thread aggregation
#         - extended statistics
#         - Chart.js dataset construction
#         - HTML rendering
#
# ARCHITECTURAL ROLE:
#     - Acts as the top-level rendering pipeline for chart+table reports.
#     - Normalizes heterogeneous result entries into a unified structure.
#
# WHAT THIS BLOCK DOES NOT DO:
#     - Does not validate semantic correctness of metrics.
#     - Does not modify filesystem outside the output file.
#
# CONTRACT:
#     - $resultsRef must be an arrayref of normalized result entries.
#     - $filename and $outputDir must be defined.
#
# GUARANTEES:
#     - Output HTML is deterministic and contributor-proof.
#-----------------------------------------------------------------------------
sub GenerateResults {
    my ($resultsRef, $filename, $outputDir) = @_;

    my $output_path = File::Spec->catfile($outputDir, "$filename.chartplus.html");

    my %data_by_user;
    my %labels_by_user;

    my $primary_name = 'Primary';
    my $testname     = 'unknown_test';
    my $host         = 'unknown_host';

    my %host_meta;

    #-------------------------------------------------------------------------
    # TAF BLOCK: Extract Subtitle and Initialize Metadata
    #
    # PURPOSE:
    #     Extract the comment field once and normalize whitespace.
    #
    # GUARANTEES:
    #     - Subtitle is always a single-line, ASCII-clean string.
    #-------------------------------------------------------------------------
    my $chart_subtitle = $resultsRef->[0]{metadata}{comments} // '';
    $chart_subtitle =~ s/\s+/ /g;

    #-------------------------------------------------------------------------
    # TAF BLOCK: Dataset Normalization and Primary Metric Extraction
    #
    # PURPOSE:
    #     Walk all result entries, extract primary metric values, collect
    #     per-thread data, and capture host/database metadata.
    #
    # ARCHITECTURAL ROLE:
    #     - Converts raw result entries into structured per-user/per-thread
    #       arrays suitable for statistical analysis.
    #
    # GUARANTEES:
    #     - Missing metadata fields fall back to safe defaults.
    #     - Only entries with valid primary metrics are included.
    #-------------------------------------------------------------------------
    foreach my $result (@$resultsRef) {

        my $tc   = $result->{thread_count};
        my $iter = $result->{iteration} // 0;
        my $user = $result->{user_id} // $result->{user_label} // 'default';

        my ($primary) = grep { $_->{type} eq 'primary' } @{ $result->{metrics} };
        next unless $primary && defined $primary->{value};

        $primary_name = $primary->{name} if $primary->{name};
        $testname     = $result->{test_name} if $result->{test_name};
        $host         = $result->{metadata}{test_host} // $host;

        # host metadata
        $host_meta{test_host}    = $result->{metadata}{test_host};
        $host_meta{cpu}          = $result->{metadata}{cpu};
        $host_meta{cpu_count}    = $result->{metadata}{cpu_count};
        $host_meta{os}           = $result->{metadata}{os};
        $host_meta{ram}          = $result->{metadata}{ram};
        $host_meta{disk}         = $result->{metadata}{disk};
        $host_meta{core_count}   = $result->{metadata}{core_count};
        $host_meta{socket_count} = $result->{metadata}{socket_count};

        push @{ $data_by_user{$user}{$tc} }, $primary->{value} + 0;

        # label: maker + version only
        my $maker   = $result->{metadata}{database_maker};
        my $version = $result->{metadata}{database_version};

        if (defined $maker && defined $version && $maker ne '' && $version ne '') {
            $labels_by_user{$user} = "$maker $version";
        }
        elsif (defined $maker && $maker ne '') {
            $labels_by_user{$user} = $maker;
        }
        else {
            $labels_by_user{$user} = $result->{metadata}{test_host} // $user;
        }
    }

    #-------------------------------------------------------------------------
    # TAF BLOCK: Per-User Averages
    #
    # PURPOSE:
    #     Compute average primary metric values per thread count for each user.
    #
    # GUARANTEES:
    #     - Averages are computed deterministically.
    #-------------------------------------------------------------------------
    my %avg_by_user;
    for my $user (keys %data_by_user) {
        for my $tc (keys %{ $data_by_user{$user} }) {
            my @vals = @{ $data_by_user{$user}{$tc} };
            my $sum = 0; $sum += $_ for @vals;
            $avg_by_user{$user}{$tc} = @vals ? $sum / @vals : 0;
        }
    }

    my @thread_counts = sort { $a <=> $b } keys %{ (values %avg_by_user)[0] };
    my $labels_js = '[' . join(',', map { "\"$_\"" } @thread_counts) . ']';

    #-------------------------------------------------------------------------
    # TAF BLOCK: Chart.js Dataset Construction
    #
    # PURPOSE:
    #     Convert per-user averages into Chart.js dataset objects.
    #
    # GUARANTEES:
    #     - JavaScript arrays are ASCII-clean and deterministic.
    #-------------------------------------------------------------------------
    my @colors = qw(#1f77b4 #d62728 #2ca02c #ff7f0e #9467bd #8c564b);
    my @datasets_js;
    my $color_idx = 0;

    for my $user (sort keys %avg_by_user) {
        my @data = map { $avg_by_user{$user}{$_} // 0 } @thread_counts;
        my $data_js = '[' . join(',', @data) . ']';
        my $color = $colors[$color_idx++ % @colors];

        my $label = $labels_by_user{$user};

        push @datasets_js, <<JS;
{
  label: "$label",
  data: $data_js,
  backgroundColor: "$color",
  borderColor: "$color",
  fill: false
}
JS
    }

    my $datasets_js = "[\n" . join(",\n", @datasets_js) . "\n]";
    my $chart_type = (@thread_counts > 1) ? 'line' : 'bar';

    my $chart_title = "$primary_name by Thread Count - $testname on $host";

    #-------------------------------------------------------------------------
    # TAF BLOCK: HTML Header and Chart Rendering
    #
    # PURPOSE:
    #     Emit the HTML header, styling, and Chart.js initialization script.
    #
    # GUARANTEES:
    #     - Output HTML is self-contained and deterministic.
    #-------------------------------------------------------------------------
    open(my $fh, '>', $output_path) or die "Cannot write HTML chart to $output_path: $!";

    print $fh <<HTML;
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>$chart_title</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    body { font-family: sans-serif; }
    .chart-container { max-width: 700px; margin: auto; }
    canvas { width: 100% !important; height: 300px !important; }
    table { border-collapse: collapse; margin: 10px auto; }
    th, td { border: 1px solid #ccc; padding: 4px 8px; }
    th { background: #eee; text-align: left; }
    td { text-align: left; }
    h3 { text-align: center; margin-top: 10px; }
    .results-grid { display: flex; flex-wrap: wrap; justify-content: center; gap: 20px; margin: 40px auto; max-width: 1200px; }
    .result-box { flex: 1 1 300px; max-width: 400px; }
  </style>
</head>
<body>
  <h2 style="text-align:center;">$chart_title</h2>
  <div style="text-align:center; color:#666; margin-top:4px;">$chart_subtitle</div>

  <div class="chart-container">
    <canvas id="chart"></canvas>
  </div>

  <script>
    const ctx = document.getElementById('chart').getContext('2d');
    const chart = new Chart(ctx, {
      type: '$chart_type',
      data: {
        labels: $labels_js,
        datasets: $datasets_js
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: 'top' },
          title:  { display: false }
        },
        scales: {
          x: { title: { display: true, text: 'Thread Count' } },
          y: { title: { display: true, text: '$primary_name' } }
        }
      }
    });
  </script>
HTML

    #-------------------------------------------------------------------------
    # TAF BLOCK: Host Metadata Table
    #
    # PURPOSE:
    #     Render a simple table of host/system metadata.
    #
    # GUARANTEES:
    #     - Missing fields are skipped safely.
    #-------------------------------------------------------------------------
    print $fh "<h3>Host Details</h3>\n";
    print $fh "<table style=\"margin: 10px auto; text-align: left;\">\n";
    print $fh "<tr><th>Property</th><th>Value</th></tr>\n";

    my %label_map = (
        test_host    => 'HOST',
        cpu          => 'CPU',
        cpu_count    => 'CPU COUNT',
        core_count   => 'CORE COUNT',
        socket_count => 'SOCKET COUNT',
        os           => 'OS',
        ram          => 'RAM',
        disk         => 'DISK',
    );

    for my $key (qw(test_host cpu cpu_count core_count socket_count os ram disk)) {
        my $val = $host_meta{$key};
        next unless defined $val && $val ne '';
        my $label = $label_map{$key} // uc($key);
        print $fh "<tr><td>$label</td><td>$val</td></tr>\n";
    }

    print $fh "</table>\n";

    #-------------------------------------------------------------------------
    # TAF BLOCK: Per-Thread Results Grid
    #
    # PURPOSE:
    #     Render extended statistics and iteration-level values for each
    #     thread count across all datasets.
    #
    # GUARANTEES:
    #     - Diff column appears only when exactly two datasets exist.
    #-------------------------------------------------------------------------
    print $fh '<div class="results-grid">';

    my %all_threads;
    for my $user (keys %data_by_user) {
        for my $tc (keys %{ $data_by_user{$user} }) {
            $all_threads{$tc} = 1;
        }
    }

    for my $tc (sort { $a <=> $b } keys %all_threads) {
        print $fh '<div class="result-box">';
        print $fh "<h3>Thread Count: $tc</h3>\n";
        print $fh "<table><tr><th>Metric</th>";

        for my $user (sort keys %data_by_user) {
            my $label = $labels_by_user{$user};
            print $fh "<th>$label</th>";
        }

        if (scalar(keys %data_by_user) == 2) {
            print $fh "<th>Diff</th>";
        }

        print $fh "</tr>\n";

        my @metrics = (
            ['Mean', sub { my @v=@_; @v ? sum(@v)/@v : 0 }],
            ['Max',  sub { my @v=@_; @v ? max(@v) : 0 }],
            ['Min',  sub { my @v=@_; @v ? min(@v) : 0 }],
            ['StdDev', sub { my @v=@_; @v ? do { my $m=sum(@v)/@v; sqrt(sum(map {($_-$m)**2} @v)/@v) } : 0 }],
            ['CoV', sub { my @v=@_; @v ? do { my $m=sum(@v)/@v; my $s=sqrt(sum(map {($_-$m)**2} @v)/@v); $m? $s/$m:0 } : 0 }],
            ['Median (p50)', sub { percentile(\@_,50) }],
            ['p95', sub { percentile(\@_,95) }],
            ['p99', sub { percentile(\@_,99) }],
            ['Skewness', sub { my @v=@_; @v ? do { my $m=sum(@v)/@v; my $s=sqrt(sum(map {($_-$m)**2} @v)/@v); skewness(\@v,$m,$s) } : 0 }],
            ['Kurtosis', sub { my @v=@_; @v ? do { my $m=sum(@v)/@v; my $s=sqrt(sum(map {($_-$m)**2} @v)/@v); kurtosis(\@v,$m,$s) } : 0 }],
        );

        for my $metric (@metrics) {
            my ($name,$calc) = @$metric;
            print $fh "<tr><td>$name</td>";
            my @vals;

            for my $user (sort keys %data_by_user) {
                my @uvals = @{ $data_by_user{$user}{$tc} // [] };
                my $val = @uvals ? $calc->(@uvals) : 0;
                push @vals, $val;
                printf $fh "<td>%.2f</td>", $val;
            }

            if (@vals == 2) {
                my $diff = diff_val($vals[0], $vals[1]);
                printf $fh "<td>%s</td>", $diff;
            }

            print $fh "</tr>\n";
        }

        # iteration rows
        my $max_iters = 0;
        for my $user (keys %data_by_user) {
            my $count = scalar @{ $data_by_user{$user}{$tc} // [] };
            $max_iters = $count if $count > $max_iters;
        }

        for my $i (1..$max_iters) {
            print $fh "<tr><td>Iteration $i</td>";
            my @vals;

            for my $user (sort keys %data_by_user) {
                my @uvals = @{ $data_by_user{$user}{$tc} // [] };
                my $val = $uvals[$i-1] // '';
                push @vals, $val if $val ne '';

                if ($val ne '') {
                    printf $fh "<td>%.2f</td>", $val;
                } else {
                    print $fh "<td>-</td>";
                }
            }

            if (@vals == 2) {
                my $diff = diff_val($vals[0], $vals[1]);
                printf $fh "<td>%s</td>", $diff;
            }

            print $fh "</tr>\n";
        }

        print $fh "</table>\n";
        print $fh "</div>\n";
    }

    print $fh "</div>\n";  # results-grid

    #-------------------------------------------------------------------------
    # TAF BLOCK: Finalization
    #
    # PURPOSE:
    #     Close HTML document, flush filehandle, and emit completion message.
    #
    # GUARANTEES:
    #     - Always returns 1 to indicate success.
    #-------------------------------------------------------------------------
    print $fh "</body></html>\n";
    close $fh or die "Failed to close $output_path cleanly";

    print "Chart+Tables HTML written to: $output_path\n";
    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;