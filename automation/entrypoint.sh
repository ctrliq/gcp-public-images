#!/bin/bash
export GOOGLE_APPLICATION_CREDENTIALS="/creds.json"

exec "$@"
