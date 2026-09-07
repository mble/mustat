# mustat

Fast descriptive statistics in pure Zig. It is a graph-free descendant of
[`ministat`](https://github.com/leahneukirchen/ministat).

```sh
zig build -Doptimize=ReleaseFast
printf '1\n2\n3\n4\n' | ./zig-out/bin/mustat
```

`mustat` reports count, minimum, quartiles, median, maximum, interquartile
range, mean, sample standard deviation, standard error, coefficient of
variation, and the 90th, 95th, and 99th percentiles.

Quantiles use R-7 linear interpolation. Dispersion uses the sample variance
(`N - 1`). Non-finite inputs are rejected.

```text
Usage: mustat [-Ahnq] [-C column] [-d delimiters] [file ...]
```

Use `-C` to select a one-based column and `-d` to provide delimiter bytes.
Blank lines, missing columns, and `#` comments are ignored. Multiple files are
reported independently; `-` reads standard input.
