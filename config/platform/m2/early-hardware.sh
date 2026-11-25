#!/bin/sh
# The USB root cannot supply the drivers needed to discover itself.
for driver in @PLATFORM_MODULES@; do
    modprobe "$driver" || echo "Ordo: could not load $driver" >&2
done
