#!/usr/bin/env bash

forge coverage --report lcov --ir-minimum

genhtml lcov.info -o coverage --branch-coverage --ignore-errors category && open coverage/index.html
