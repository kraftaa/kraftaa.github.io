---
layout: post
title: "Fixing the lack of DBT dry-run option"
date: 2025-5-01
img: dbt.png
tags: [Kubernetes, DBT]
---

## Table of Contents
- [Problem](#problem)
- [The Solution](#the-solution)
  - [The Hacky but Effective Solution](#the-hacky-but-effective-solution)
  - [Alternative: Use a Dummy Database](#alternative-use-a-dummy-database)


## Problem:

**Lack of dry-run option in DBT**: 

One of the frustrating limitations in **dbt** today is the lack of a proper dry-run mode — something that could check:
- if your models reference columns or tables that actually exist/don't exist in the database tables/models
- if the syntax is correct
- if there is a set of duplicating columns

without actually materializing the models.

The existing options, which look like possible options, don't do that:

**_dbt compile_** - only checks if the models themselves exist, _Jinja_ syntax and compiles the existing models into the _sql_ files in _target/compiled_ directory

**_dbt empty_** - runs the code against database creating empty views/tables and it's only if you don't use _ref_ model syntax.
syntax,
here **dbt** breaks with _limit 0_ error

**_dbt build_** - runs the actual code

**_dbt parse_** - gives the performance info

**_dbt debug_** - only tests the connection and the environment

It is the main limiting factor as we can't merge models into production without knowing if they are going to break.
The re is no hope **dbt** fixing it, as according to their issues in github, that idea is removed from the roadmap, hence I have to figure out how to solve it by myself.


## The Solution:

Fixing the Lack of a dbt Dry-Run

####  The Hacky but Effective Solution

I built a dry-run-like pipeline using a combination of dbt compile, psql, and some Bash scripting. Here's what it does:


**Compiles the models:** Runs dbt compile to render SQL for the modified models into the target/compiled directory.

**Adds LIMIT 0:** Modifies the compiled SQL files for the models in order to append LIMIT 0 to the end of each SELECT statement — this forces Postgres to validate the query structure and column existence without executing it.

**Runs the queries:** Executes the altered files against the real database.

**Catches errors:** Any missing columns, typos, or duplicates will cause the queries to fail fast — just like a dry-run should.


**Bonus Feature**

The script also:

Extracts column names from each result set.

Checks for duplicate column names (a common silent failure in joins and complicated models)

**Caveats**

You can't check multiple interdependent models together unless they already exist in the database, need to run first the base/bronze level models, then silver, then gold.

I need to  add LIMIT 0 in compiled files.


The full code for adding _**LIMIT 0**_ and running database check  [**is here**](https://gist.github.com/kraftaa/0a72a8ae35f92f2d9a3a2c12d2f686b0).


####  Alternative: Use a Dummy Database

One workaround we found was to spin up a dummy Postgres database seeded with just the schema (no data) from the actual production. 
Then dbt runs against that to validate the models structurally. That avoids most risks of polluting production.

The production schema from the primary database could be copied and loaded into the new database like that:
```shell
# Export the schema
PGPASSWORD=password pg_dump \
  --host=PRODUCTION_HOST \
  --username=PRODUCTION_USER \
  --dbname=PRODUCTION_DB \
  --schema=public \
  --schema-only \
  --no-owner \
  --no-privileges \
  > public_schema.sql

# Creating target DB
createdb --host=EMPTY_DB_HOST --username=EMPTY_DB_USER EMPTY_DB

# Import the schema
PGPASSWORD=password psql \
  --host=EMPTY_DB_HOST \
  --username=EMPTY_DB_USER \
  --dbname=EMPTY_DB \
  < public_schema.sql
```

The caveat here: you need to update the schema from your primary instance either by cloning the schema file from your app repo, or running schema updates with these commands with each migration (need to be automated).

If you’ve hit issues where dbt run fails halfway through because of a missing column, or you want to validate transformations during CI/CD without building the models—this method is for you.