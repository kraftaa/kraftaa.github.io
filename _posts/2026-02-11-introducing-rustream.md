---
layout: post
title: "Introducing rustream: A Fast Postgres to Parquet Sync Tool in Rust"
date: 2026-02-11
img: rustacean-flat-happy.svg
tags: [Rust, Postgres, Parquet, S3, ETL, Arrow, Iceberg]
excerpt: "rustream is a lightweight Rust CLI that syncs Postgres tables to Parquet files on local disk or S3, with incremental watermark tracking and upcoming Apache Iceberg support."
excerpt_separator: <!--more-->
---

Hey there!

If you've read my [previous post on building a cloud-native ETL with Rust]({% post_url 2025-2-28-etl-postgres-to-parquet-s3 %}), you'll know we spent a lot of time wiring up Postgres reads, Parquet writes, and S3 uploads by hand. **rustream** is the next evolution of that work -- a focused, open-source CLI tool that does one thing well: sync Postgres tables to Parquet.

<!--more-->

## Why rustream?

The original [Dracula](https://github.com/kraftaa/dracula) project taught us a lot, but it was tightly coupled to our specific tables and schemas. Every new table meant writing a new Rust struct, a Diesel schema macro, and a Parquet record writer. It worked, but it didn't scale in terms of developer time.

**rustream** takes a different approach: it introspects your Postgres schema at runtime using `information_schema`, automatically maps column types to Arrow data types, and writes Parquet files without any per-table code. You just point it at your database and go.

The code is on GitHub: [**kraftaa/rustream**](https://github.com/kraftaa/rustream)

## How It Works

The tool is a single Rust binary. You give it a YAML config file that specifies your Postgres connection and output target:

```yaml
postgres:
  host: localhost
  database: mydb
  user: postgres
  password: secret

output:
  type: local
  path: ./output

tables:
  - name: users
    incremental_column: updated_at
  - name: orders
    incremental_column: updated_at
    partition_by: date
  - name: products
```

Then run:

```bash
dracula sync --config config.yaml
```

That's it. It connects to Postgres, reads each table in batches, converts rows to Arrow RecordBatches, writes Snappy-compressed Parquet files, and uploads them to local disk or S3.

## Key Features

**Schema introspection** -- No need to define Rust structs for each table. The tool queries `information_schema.columns` and maps Postgres types (int, text, timestamptz, jsonb, uuid, etc.) to Arrow types automatically.

**Incremental sync** -- Set an `incremental_column` (like `updated_at`) and the tool tracks a high watermark in a local SQLite database. On each run it only reads rows newer than the last sync.

**Partitioned output** -- Partition Parquet files by date, month, or year. An orders table with `partition_by: date` produces paths like `orders/year=2026/month=02/day=11/...parquet`.

**S3 support** -- Switch the output to S3 by changing a few lines in the config:

```yaml
output:
  type: s3
  bucket: my-data-lake
  prefix: raw/postgres
  region: us-east-1
```

AWS credentials come from the standard chain (env vars, `~/.aws/credentials`, or IAM role).

**Auto-discovery** -- Don't want to list tables explicitly? Remove the `tables` key and set `schema: public`. The tool discovers all tables in the schema and syncs them, with an `exclude` list for tables you want to skip.

## What Changed from the Original Dracula

The biggest shift is moving from **Diesel ORM + per-table structs** to **tokio-postgres + Arrow**. In the original project, adding a table meant:

1. Run `diesel print-schema` to generate the table macro
2. Write a `Queryable` struct matching the schema
3. Write a `ParquetRecordWriter` struct for the output
4. Wire up the read-transform-write pipeline

In rustream, adding a table means adding three lines to the YAML config. The runtime handles the rest.

We also switched from synchronous Diesel to fully async `tokio-postgres`, which plays better with the async S3 SDK and lets us handle I/O concurrently.

## Architecture

The data flow is straightforward:

```
Postgres
  -> reader::read_batch()        -- SQL query with watermark filter
  -> Arrow RecordBatch            -- in-memory columnar data
  -> writer::write_parquet()      -- Snappy-compressed Parquet buffer
  -> output::write_output()       -- local filesystem or S3
```

The codebase is small -- about 8 Rust source files:

- `config.rs` -- YAML config parsing with serde
- `schema.rs` -- Postgres schema introspection
- `types.rs` -- Postgres-to-Arrow type mapping
- `reader.rs` -- Batch reading from Postgres
- `writer.rs` -- Parquet serialization
- `output.rs` -- Local/S3 output abstraction
- `state.rs` -- SQLite watermark tracking
- `sync.rs` -- Orchestration loop

## Coming Soon: Apache Iceberg Support

I'm currently working on Iceberg output support on a feature branch. Instead of writing standalone Parquet files, rustream will be able to write proper Iceberg tables with metadata JSON, manifests, and snapshots. This means query engines like Athena, Trino, and Spark can read the data as a real table with time travel and schema evolution.

The config will look like:

```yaml
format: iceberg
warehouse: s3://my-bucket/warehouse
catalog:
  type: filesystem
```

Under the hood, I'm using the official [Apache Iceberg Rust crate](https://crates.io/crates/iceberg) (v0.8) with its `MemoryCatalog` for filesystem-based catalogs, and optional AWS Glue catalog support for Athena users.

## Installation

You can install directly from PyPI -- it ships as a pre-built Python wheel via maturin, so you get a native Rust binary without needing a Rust toolchain:

```bash
pip install rustream
```

Or if you prefer isolated tool installs:

```bash
pipx install rustream
```

Or build from source:

```bash
git clone https://github.com/kraftaa/rustream.git
cd rustream
cargo build --release
```

## Also Check Out: TransformDash

If you're interested in the transformation side of the pipeline, I also built [**TransformDash**](https://github.com/kraftaa/transformdash) -- a lightweight alternative to dbt that runs SQL transformations directly against your Postgres or MongoDB without needing a dedicated data warehouse. It supports dbt-style `{{ ref() }}` and `{{ source() }}` macros, DAG resolution, and has a built-in dashboard for quick data checks.

It's also available on PyPI:

```bash
pip install transformdash
```

You can read more about it in my [earlier post]({% post_url 2025-11-18-building-transformdash %}).

## Try It Out

If you're syncing Postgres tables to a data lake and want something simpler than Airbyte or Fivetran, give rustream a try. It's lightweight, fast, and doesn't require a JVM or Python runtime.

```bash
# Preview what will be synced
dracula sync --config config.yaml --dry-run

# Run the sync
dracula sync --config config.yaml
```

Check out the repo: [**github.com/kraftaa/rustream**](https://github.com/kraftaa/rustream)

Questions or feedback? Open an issue on GitHub.
