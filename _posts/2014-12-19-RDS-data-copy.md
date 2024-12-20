---
layout: post
title: "Syncing Postgreql databases with Rust"
date: 2024-12-17
img: postgresql3.png
tags: [Rust, Postgres, DBT]
---

!!! Work in progress, many additions coming !!!

## Problem:
We need to be able to run DBT models on the Postgres RDS database, but can't write into existing RDS Postgres read replica.