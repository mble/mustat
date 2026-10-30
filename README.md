# mustat

Fast descriptive statistics in pure Zig. It is a graph-free descendant of
[`ministat`](https://github.com/leahneukirchen/ministat).
The command-line interface is supported; the internal Zig modules are not a
public library API.

```sh
zig build -Doptimize=ReleaseFast
printf '1\n2\n3\n4\n' | ./zig-out/bin/mustat
```

The default summary matches `ministat`: count, minimum, maximum, median, mean,
and sample standard deviation. Use `-x` for quartiles, interquartile range,
standard error, and coefficient of variation. Use `-p` for the 90th, 95th,
and 99th percentiles. The flags combine.

With multiple files, each dataset after the first is compared with the first
using a two-sided Welch t-test. Welch's form avoids assuming equal variances.
Use `-c` to set the confidence percentage or `-n` to suppress comparisons.
The test assumes independent observations and approximately normal sample
means; paired measurements require a paired test instead.

Quantiles use R-7 linear interpolation. Dispersion uses the sample variance
(`N - 1`). Non-finite inputs are rejected.

```text
Usage: mustat [-Ahnjpqx] [-C column] [-c confidence] [-d delimiters] [file ...]
```

Use `-C` to select a one-based column and `-d` to provide delimiter bytes.
Blank lines, missing columns, and `#` comments are ignored. Multiple files are
reported independently; `-` reads standard input. Use `-h` for adaptive,
eight-significant-digit number formatting. Use `--help` for usage.

Use `-j` or `--json` to write one JSON document. It has a `datasets` array in
input order. Each entry has a `name` and a `stats` object. By default, `stats`
contains `count`, `min`, `max`, `median`, `mean`, and `stddev`. `-x` adds `q1`,
`q3`, `iqr`, `stderr`, and `cv_percent`; `-p` adds `p90`, `p95`, and `p99`.
Undefined or non-finite results are `null`. Each dataset after the first has a
`comparison` object unless `-n` is set. It names the baseline and has an
`available` flag. Available comparisons include `difference`,
`relative_percent`, `statistic`, `degrees_of_freedom`, `p_value`,
`confidence_percent`, and `significant`. `-h` and `-q` affect text output only.

## Example

Using the [`ministat` example](https://github.com/leahneukirchen/ministat#example):

```sh
cat >iguana <<'EOF'
50
200
150
400
750
400
150
EOF

cat >chameleon <<'EOF'
150
400
720
500
930
EOF

./zig-out/bin/mustat -h iguana chameleon
```

```text
iguana
       N           Min           Max        Median           Avg        Stddev
       7            50           750           200           300     238.04761
chameleon
       N           Min           Max        Median           Avg        Stddev
       5           150           930           500           540     299.08193
Welch t-test chameleon vs iguana:
  delta=240 (80%), t=1.4888395, df=7.4254283, p=0.17772184
  no difference at 95.0% confidence
```

### JSON output

Using the same measurements:

```sh
cat >iguana <<'EOF'
50
200
150
400
750
400
150
EOF

cat >chameleon <<'EOF'
150
400
720
500
930
EOF

./zig-out/bin/mustat --json iguana chameleon | python3 -m json.tool
```

```json
{
    "datasets": [
        {
            "name": "iguana",
            "stats": {
                "count": 7,
                "min": 50,
                "max": 750,
                "median": 200,
                "mean": 300,
                "stddev": 238.04761428476166
            }
        },
        {
            "name": "chameleon",
            "stats": {
                "count": 5,
                "min": 150,
                "max": 930,
                "median": 500,
                "mean": 540,
                "stddev": 299.0819285747636
            },
            "comparison": {
                "baseline": "iguana",
                "available": true,
                "difference": 240,
                "relative_percent": 80,
                "statistic": 1.488839530990719,
                "degrees_of_freedom": 7.425428321242507,
                "p_value": 0.1777218415434041,
                "confidence_percent": 95,
                "significant": false
            }
        }
    ]
}
```

## Performance

Input bytes are streamed; only parsed values are retained for exact quantiles.
Lines are limited to 1 MiB and retained values to 4 GiB.
The hot path uses SIMD compensated accumulation, SIMD extrema detection, and
bounded multi-selection instead of fully sorting every dataset. Run with:

```sh
zig build benchmark -Doptimize=ReleaseFast
```

## Releases

Tags such as `v0.1.0` publish stripped, static Linux binaries for amd64 and
arm64, plus SHA-256 checksums. The tag must match `build.zig.zon`.
