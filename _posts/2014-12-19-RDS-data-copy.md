---
layout: post
title: "Syncing Postgreql databases with Rust"
date: 2024-12-17
img: postgresql3.png
tags: [Rust, Postgres, DBT]
---
_Contains code, waiting for the full description_
&nbsp;

## Problem:
We need to be able to run DBT models on the Postgres RDS database, but can't write into existing RDS Postgres read replica.

Will add a descriptions to the steps in [this repo](https://github.com/kraftaa/postgres_data_sync)  and DBT steps to incrementally update existing table.