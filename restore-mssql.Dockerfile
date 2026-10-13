ARG MSSQL_IMAGE=mcr.microsoft.com/mssql/server:2022-CU27-GDR1-ubuntu-22.04

FROM ${MSSQL_IMAGE}

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends unzip \
  && rm -rf /var/lib/apt/lists/*
USER mssql
