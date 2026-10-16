#!/usr/bin/env bash
# ExecStopPost: systemd runs this after the pit's unit stops, however it stopped.
echo "$(date +%Y-%m-%dT%H:%M:%S.%3N) vessel terminal result=${SERVICE_RESULT:-?} exit=${EXIT_CODE:-?}/${EXIT_STATUS:-?}" >> "$1"
