# Test-only vendored library

`theft` v0.4.5 (commit `62e093d`, ISC license) is used only by the native C
property suite under `test/property`; it is never linked into Rducks. This copy
includes the upstream-compatible shift-by-64 guard used by `ducknng` so the test
runner itself remains clean under UBSan.
