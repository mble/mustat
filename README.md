# mustat

Fast descriptive statistics in pure Zig. It is a graph-free descendant of
[`ministat`](https://github.com/leahneukirchen/ministat).

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
Usage: mustat [-Ahnpqx] [-C column] [-c confidence] [-d delimiters] [file ...]
```

Use `-C` to select a one-based column and `-d` to provide delimiter bytes.
Blank lines, missing columns, and `#` comments are ignored. Multiple files are
reported independently; `-` reads standard input. Use `-h` for adaptive,
eight-significant-digit number formatting. Use `--help` for usage.

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

## Performance

Input bytes are streamed; only parsed values are retained for exact quantiles.
The hot path uses SIMD compensated accumulation, SIMD extrema detection, and
bounded multi-selection instead of fully sorting every dataset. Run with:

```sh
zig build benchmark -Doptimize=ReleaseFast
```
