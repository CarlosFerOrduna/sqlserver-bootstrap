FROM mcr.microsoft.com/mssql/server:2022-latest

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends unzip \
  && rm -rf /var/lib/apt/lists/*
USER mssql
