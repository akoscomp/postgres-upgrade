#!/usr/bin/env bash
docker build -t akoscomp/postgres-upgrade:18 -t akoscomp/postgres-upgrade:latest  ./postgres-upgrade
docker push akoscomp/postgres-upgrade:18
docker push akoscomp/postgres-upgrade:latest
