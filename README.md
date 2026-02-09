[![CI](https://github.com/haxmeister/perl-linux-event/actions/workflows/ci.yml/badge.svg)](https://github.com/haxmeister/perl-linux-event/actions/workflows/ci.yml)

# Linux-Event 0.001_001

**EXPERIMENTAL / WORK IN PROGRESS**

This is an early development release of the Linux::Event ecosystem.

## What this provides (today)

- `Linux::Event` front door
- `Linux::Event::Loop` backend-agnostic loop
- `Linux::Event::Scheduler` deadline scheduler (ns)
- `Linux::Event::Backend::Epoll` backend using `Linux::Epoll`

## External prerequisites

This distribution depends on existing published modules:

- `Linux::Event::Timer` >= 0.010
- `Linux::Event::Clock` >= 0.011
- `Linux::Epoll`

## Status

The API is not stable yet and may change without notice.
Not recommended for production use.

## Quick test

```bash
perl Makefile.PL
make test
```
