---
layout: post
title: "Building a Cloud-Native ETL with Rust: A Retrospective"
date: 2024-12-17
img: rustacean-flat-happy.svg
tags: [Rust, AWS, S3, Postgres]
---

<style>
  .toc-sidebar {
    position: fixed;
    left: 20px; /*260px  Move TOC to the right of the sidebar */
    top: 280px; /* 80px */
    width: 200px;
    max-height: 54vh;
    overflow-y: auto; /* Enables scrolling */
    padding: 10px;
    background: #f8f9fa;
    border-radius: 5px;
    border: 1px solid #ddd;
    box-shadow: 2px 2px 5px rgba(0, 0, 0, 0.1);
    font-size: 14px;
    z-index: 1000;
}

  .toc-sidebar ul {
      list-style: none;
      padding-left: 0;
  }

  .toc-sidebar li {
      margin-bottom: 5px;
  }

  .toc-sidebar a {
      text-decoration: none;
      color: #0073e6;
  }

  .toc-sidebar a:hover {
      text-decoration: underline;
  }

  .content {
  margin-left: 480px; /* Adjust so the main content does not overlap */
  max-width: 800px;
}
</style>


<nav class="toc-sidebar">
  <h3>Table of Contents</h3>
  <ul>
    <li><a href="#problem">1. Problem</a></li>
    <li><a href="#data-warehouses">2. Data Warehouses</a>
      <ul>
        <li><a href="#security">2.1 Security</a></li>
        <li><a href="#performance">2.2 Performance Considerations</a></li>
        <li><a href="#complexity">2.3 Execution Complexity in ETL</a></li>
      </ul>
    </li>
    <li><a href="#why-rust">3. Why Rust</a>
      <ul>
        <li><a href="#context">3.1 The Context and Alternatives</a></li>
        <li><a href="#type-safety">3.2 Type Safety</a></li>
        <li><a href="#challenges-rust">3.3 The Challenges of Working with Rust</a></li>
      </ul>
    </li>
    <li><a href="#etl">4. A Homemade Cloud-Native ETL Pipeline</a>
      <ul>
        <li><a href="#rust-diesel">4.1 Rust + Diesel for Postgres</a></li>
        <li><a href="#rust-sqlx">4.2 Rust + SQLX for Postgres</a></li>
        <li><a href="#s3-parquet">4.3 S3 Integration and Parquet Output</a></li>
      </ul>
    </li>
    <li><a href="#parallelism">5. Parallelism and Task Management</a>
      <ul>
        <li><a href="#asynchronous-tokio">5.1 Asynchronous Data Processing with Tokio</a></li>
        <li><a href="#parallel-rayon">5.2 Parallel Data Processing with Rayon</a></li>
        <li><a href="#memory-management">5.3 Memory Management Considerations</a></li>
      </ul>
    </li>
    <li><a href="#complex-types">6. Handling Complex Data Types</a>
      <ul>
        <li><a href="#decimal-finance">6.1 Numeric Precision: Decimal & Financial Data</a></li>
        <li><a href="#date-time">6.2 Working with Dates & Time Zones</a></li>
        <li><a href="#date-jsonb-array">6.3 Structuring Complex Data: JSONB & Arrays</a></li>
      </ul>
    </li>
    <li><a href="#reflecting">7. Reflecting on the Project</a>
      <ul>
        <li><a href="#rust-versions">7.1 Rust Versioning Challenges</a></li>
        <li><a href="#orm-pros-cons">7.2 The Pros and Cons of Diesel ORM</a></li>
        <li><a href="#operational-complexity">7.3 Operational Maintenance of a Custom ETL</a></li>
      </ul>
    </li>
    <li><a href="#conclusion">8. Conclusion: Lessons Learned and Moving Forward</a>
      <ul>
        <li><a href="#takeways">8.1 Key Takeaways</a></li>
        <li><a href="#future">8.2 Future Directions</a></li>
      </ul>
    </li>
  </ul>
</nav>



[//]: # (## Table of Contents)

[//]: # (- [1. Problem]&#40;#problem&#41;)

[//]: # (- [2. Data Warehouses]&#40;#data-warehouses&#41;)

[//]: # (    - [2.1. Security]&#40;#security&#41;)

[//]: # (    - [2.2. Performance]&#40;#performance&#41;)

[//]: # (    - [2.3 Operational Complexity]&#40;#complexity&#41;)

[//]: # (- [3. Why Rust]&#40;#why-rust&#41;)

[//]: # (    - [3.1. The Context and Alternatives]&#40;#context&#41;)

[//]: # (    - [3.2 Type Safety]&#40;#type-safety&#41;)

[//]: # (    - [3.3 Performance Considerations]&#40;#preformance-rust&#41;)

[//]: # (    - [3.4 The Challenges of Working with Rust]&#40;#challenges-rust&#41;)

[//]: # (- [4. A Homemade Cloud-Native ETL Pipeline]&#40;#etl&#41;)

[//]: # (    - [4.1 Rust + Diesel for Postgres]&#40;#rust-diesel&#41;)

[//]: # (    - [4.2 Rust + SQLX for Postgres]&#40;#rust-sqlx&#41;)

[//]: # (    - [4.3 Rust's Type Safety in the ETL Process]&#40;#rust-type-safety&#41;)

[//]: # (    - [4.4 S3 Integration and Parquet Output]&#40;#s3-parquet&#41;)

[//]: # (- [5. Parallelism and Task Management]&#40;#parallelism&#41;)

[//]: # (    - [5.1 Asynchronous Data Processing with Tokio]&#40;#asynchronous-tokio&#41;)

[//]: # (    - [5.2 Parallel Data Processing with Rayon]&#40;#parallel-rayon&#41;)

[//]: # (    - [5.3 Memory Management Considerations]&#40;#memory-management&#41;)

[//]: # (- [6. Handling Complex Data Types]&#40;#complex-types&#41;)

[//]: # (    - [6.1 Decimal Handling for Financial Data]&#40;#decimal-finance&#41;)

[//]: # (    - [6.2 Date and Time Handling]&#40;#date-time&#41;)

[//]: # (    - [6.3 Jsonb and Array]&#40;#date-jsonb-array&#41;)

[//]: # (- [7. Monitoring and Observability]&#40;#monitoring&#41;)

[//]: # (    - [7.1 Structured Logging]&#40;#logging&#41;)

[//]: # (    - [7.2 Metrics and Alerting]&#40;#logging&#41;)

[//]: # (- [8. Reflecting on the Project: What Went Right and What Didn't]&#40;#reflecting&#41;)

[//]: # (  - [8.1 Rust Versioning Challenges]&#40;#rust-versions&#41;)

[//]: # (  - [8.2 The Pros and Cons of Diesel ORM]&#40;#orm-pros-cons&#41;)

[//]: # (  - [8.3 Operational Complexity with a Homemade ETL]&#40;#operational-complexity&#41;)

[//]: # (- [9. Conclusion: Lessons Learned and Moving Forward]&#40;#conclusion&#41;)

[//]: # (  - [9.1 Key Takeaways]&#40;#takeways&#41;)

[//]: # (  - [9.2 Future Directions]&#40;#future&#41;)

Hey there! 

This is a walkthrough of a cloud-native ETL pipeline we built using Rust.
It was a fascinating project, both for the challenges we faced and the lessons we learned along the way.
It was originally started by my colleague and Rust wizard [**Xavier Lange**](https://github.com/xrl).
We were dealing with everything from Postgres integration to writing Parquet files on AWS S3, with a focus on performance, type safety, and keeping operational headaches to a minimum. 

Let's break it down.

<strong><span id="problem">1. Problem</span></strong>

This whole thing started a few years back when we needed a solution for company reporting without an established ETL process.
Our production data lived in a Postgres RDS database, but pulling reports directly from the primary instance wasn't going to work - it would've put extra load on the main app and required additional roles to handle live production data.
Plus, we needed to run complex calculations and aggregations, then store those processed results for reporting later. 
Postgres is great for transactional workloads, but we hit some walls when it came to heavy computations and data enrichment, and we could not run ML computations on live data.
And we didn't want to denormalize the tables by storing all the calculated fields in Postgres.

<strong><span id="data-warehouses">2. Data Warehouses</span></strong>

Choosing the Right Backend

When building a cloud-native ETL pipeline, picking the right data warehouse is crucial. Here's what we focused on:

**<span id="security">2.1. Security</span>**

Security was non-negotiable in our design. We made sure all data transfers were encrypted and followed industry-standard security practices for both storage and access control. Going with cloud-native solutions like AWS S3 let us easily incorporate encryption and access management best practices.

For our ETL pipeline, we layered security at multiple levels:

_Transport Layer Security_: All data moving between our ETL components and storage systems (Postgres, S3) uses TLS encryption.

_IAM Role-Based Access_: We used AWS IAM roles with the principle of the least privilege - components only get access to what they absolutely need.

_Data Encryption_: We set up server-side encryption for data at rest in S3, with Amazon S3 managed keys.

_Secrets Management_: Database credentials and API keys live safely in Kubernetes secrets.

These measures combine to create a defense-in-depth approach that keeps our data pipeline secure.

**<span id="performance">2.2. Performance Considerations</span>**

Handling large-scale data efficiently is crucial for our ETL pipeline. By optimizing Postgres queries and leveraging Rust’s concurrency model, we achieve high throughput while keeping resource usage minimal. Rust’s low-level memory control further reduces overhead during batch processing, making it well-suited for cloud environments.

Our key performance optimizations include:

_Efficient Streaming_: Processing large tables in chunks to prevent memory bloat and ensure smooth execution.

_Concurrent Execution_: Using Rust’s async runtime (Tokio) for non-blocking I/O and Rayon for parallel data processing, maximizing CPU efficiency.

_Optimized Storage_: Writing output in Parquet, a columnar format that improves query performance and reduces storage costs.

_Query Optimization_: Leveraging database indexes and crafting efficient SQL queries to minimize unnecessary reads and computations.

_Minimal Memory Overhead_: Rust’s zero-cost abstractions and lack of garbage collection ensure predictable and efficient memory usage.

_Small Binaries_: Compiled Rust applications remain under 250MB, making deployments faster and more scalable.

These optimizations allow us to process millions of records daily while maintaining high speed, low latency, and minimal infrastructure costs. For time-sensitive workloads, this translates directly into fresher insights and better decision-making.

**<span id="complexity">2.3 Execution Complexity in ETL</span>**

Scaling an ETL pipeline often introduces complexity, but Rust’s type safety helped us maintain reliability while reducing operational overhead.

In traditional Python-based ETL pipelines, many errors only surface at runtime—sometimes after the pipeline has been running for hours. With Rust, we catch these issues at compile time, ensuring:

_Fewer Production Incidents_: Type mismatches and null pointer issues are eliminated before deployment, preventing corrupt data from entering reports.

_Lower Monitoring Overhead_: Since many errors are caught at compile-time, we spend less time building extensive monitoring for runtime failures.

_Clearer Error Handling_: Rust’s Result and Option types enforce explicit handling of edge cases, leading to more robust and predictable code.

By prioritizing performance and correctness, we built an ETL pipeline that is both fast and reliable—without excessive operational complexity.

**<span id="why-rust">3. Why Rust</span>**

**The Perfect Language for Cloud-Native ETL**

Rust wasn't the first choice for ETL when we started this project. The data engineering was mostly focused on Python, Scala (with Spark), and specialized tools like _dbt_. Here's why we went against the mainstream solutions with Rust, and what other options we considered.

**<span id="context">3.1. The Context and Alternatives</span>**

When we started this project, we looked at the next options:

_Apache Spark_: It's powerful, but Spark would bring too much operational complexity and resource overhead for our relatively modest data volumes (tens of GBs rather than TBs).
Spark (we tried PySpark) was doing great job with workers but all of them were dependent on the master and Java errors' description wasn't the best, making it harder to debug.

_Python-based ETL_: Airflow was getting popular, but we had concerns about type safety and performance with Python for what we needed to do. Python dataframes were struggling with our big tables especially with the cross-table calculations.
We could include pure SQL code into Airflow DAGs, but it would violate our security considerations.

_dbt_: Was lacking some features we needed for raw data extraction and transformation. We also had many methods in our application whose implementation in SQL would require many intense recursive queries.

We needed something lightweight but powerful, with high performance and strong type safety. 
Rust looked promising.

**<span id="type-safety">3.2 Type Safety</span>**

Rust's type safety plays a pivotal role in ensuring the reliability and correctness of our ETL pipeline. Unlike dynamically typed languages like Python, where type mismatches can only be detected at runtime, Rust catches these issues at compile-time, eliminating a large class of potential runtime errors and enhancing the overall safety and stability of our pipeline.

Enforcing Type Safety at the Database Level
Rust’s strong type system is particularly effective when working with databases. By using Rust's types alongside Diesel's ORM, we ensure that the data models are well-validated before they interact with our database. 

Here's an example of how we define a model:

```rust
use bigdecimal::BigDecimal;
use chrono::NaiveDateTime;

#[derive(Queryable, Debug, sqlx::FromRow)]
pub struct Currency {
  pub id: i32,
  pub exchangable_id: Option<i32>,
  pub exchangable_type: Option<String>,
  pub currency: Option<String>,
  pub conversion_rate: Option<BigDecimal>,
  pub conversion_set_at: Option<NaiveDateTime>,
  pub conversion_history: Option<serde_json::Value>,
  pub created_at: Option<NaiveDateTime>,
  pub updated_at: Option<NaiveDateTime>,
}
```
This model achieves several things:

It maps directly to our Postgres table through Diesel's ORM.
It enforces type safety when reading data from the database.
It validates data before serialization to Parquet.
The compiler ensures that we handle all potential type mismatches, null values, and conversion errors, making our pipeline robust and reliable.

_Type Safety in Data Transformation_

In our ETL pipeline, transforming data between different formats (such as from Postgres to Parquet) also benefits from Rust’s strict type checks. 

Here's how we define a transformation from our database model to our Parquet output model:

```rust
#[derive(ParquetRecordWriter)]
struct CurrencyRecord {
  id: i32,
  exchangable_id: Option<i32>,
  exchangable_type: Option<String>,
  currency: Option<String>,
  conversion_rate: f64,
  conversion_set_at: Option<NaiveDateTime>,
  conversion_history: Option<String>,
  created_at: Option<NaiveDateTime>,
  updated_at: Option<NaiveDateTime>,
}

pub fn currencies(pg_uri: &str) -> (String, i64) {
  let conn = PgConnection::establish(pg_uri).unwrap();

  let currencies_load = Instant::now();
  let currencies = currencies_dsl::currencies.load::<Currency>(&conn).unwrap();

  pub fn currencies(pg_uri: &str) -> (String, i64) {
    let conn = PgConnection::establish(pg_uri).unwrap();
    let currencies_load = Instant::now();
    let currencies = currencies_dsl::currencies.load::<Currency>(&conn).unwrap();

    let path = "/tmp/currencies.parquet";

    let records: Vec<CurrencyRecord> = currencies
            .iter()
            .map(|c| {
              let conversion_history = c.conversion_history.as_ref().map(|h| h.clone().to_string());

              CurrencyRecord {
                id: c.id,
                exchangable_id: c.exchangable_id,
                exchangable_type: c.exchangable_type.clone(),
                currency: c.currency.clone(),
                conversion_rate: c
                        .conversion_rate
                        .as_ref()
                        .unwrap()
                        .to_f64()
                        .expect("big decimal rate"),
                conversion_set_at: c.conversion_set_at,
                conversion_history,
                created_at: c.created_at,
                updated_at: c.updated_at,
              }
            })
            .collect();
```

The compiler ensures that every field is properly accounted for. If we change the structure of _CurrencyRecord_, we'll get compile-time errors in all the places that create or use that struct, ensuring we don't miss any updates.


**<span id="challenges-rust">3.3 The Challenges of Working with Rust</span>**

Rust’s ownership model, borrowing rules, and strict type system introduced an initial learning curve. Managing large datasets efficiently required deep familiarity with Rust’s concurrency model.

We also faced challenges in:

_Long compile times_ impacting iteration speed.

_Dependency management_ across macOS (local) and Kubernetes (Ubuntu-based) environments.

_Smaller ecosystem_ compared to Python and Java, requiring more custom solutions.

For a detailed breakdown of the operational complexities, including Diesel ORM’s schema handling and ETL challenges, see Section [8.2](#rust-versions) and [8.3](#orm-proc-cons).

**<span id="etl">4. A Homemade Cloud-Native ETL Pipeline</span>**

Here what we had in mind for our ETL pipeline:

<div class="mermaid">
flowchart TD;
RustProgram[Rust Program] -->|Reads| PostgresRDS[PostgreSQL RDS];
RustProgram -->|Calculates & Aggregates & Writes| S3ParquetFiles[S3 Parquet Files];
RustProgram -->|Updates & Starts| AWS_GLUE[AWS Glue Crawler];
AWS_GLUE[AWS Glue Crawler]-->|Crawls & Creates Schema| S3ParquetFiles[S3 Parquet Files];
S3ParquetFiles[S3 Parquet Files] -->|Tables via Glue Schema| AWSAthena[AWS Athena];
AWSAthena -->|Used in| Reports[Reports];

    %% Adding styles for clarity
    classDef process fill:#f9f,stroke:#333,stroke-width:2px;
    class RustProgram,PostgresRDS,S3ParquetFiles,AWS_GLUE,AWSAthena,Reports process;
</div>

Instead of performing everything within Postgres, we built our ETL pipeline with Rust, and it runs smoothly on AWS infrastructure.
Our Rust project is called **Dracula** because it carefully sips production data without draining the system dry.

The full code (condenced and without specific tables is located [**here**](https://github.com/kraftaa/dracula)).


**<span id="rust-diesel">4.1 Rust + Diesel for Postgres</span>**

For mapping structs and tables and for reading small tables we are using Diesel, synchronous Rust ORM.

```rust
pub use diesel::pg::PgConnection;

pub fn taxes(pg_uri: &str) -> (String, i64) {
    let pgconn = PgConnection::establish(pg_uri).unwrap();

    let taxes = taxes_dsl::taxes.load::<Tax>(&pgconn).unwrap();
```

Diesel also provides strong type checking between our Rust code and the database schema:
```rust
// dracula_schemas/src/tables/currencies_tl.rs for the table
table! {
    currencies (id) {
        id -> Int4,
        exchangable_id -> Nullable<Int4>,
        exchangable_type -> Nullable<Varchar>,
        currency -> Nullable<Varchar>,
        conversion_rate -> Nullable<Numeric>,
        conversion_set_at -> Nullable<Timestamp>,
        conversion_history -> Nullable<Jsonb>,
        created_at -> Nullable<Timestamp>,
        updated_at -> Nullable<Timestamp>,
    }
}

```

// Our model must match this schema
```rust
// dracula_schemas/src/models/currencies.rs for the struct
use bigdecimal::BigDecimal;
use chrono::NaiveDateTime;

#[derive(Queryable, Debug, sqlx::FromRow)]
pub struct Currency {
  pub id: i32,
  pub exchangable_id: Option<i32>,
  pub exchangable_type: Option<String>,
  pub currency: Option<String>,
  pub conversion_rate: Option<BigDecimal>,
  pub conversion_set_at: Option<NaiveDateTime>,
  pub conversion_history: Option<serde_json::Value>,
  pub created_at: Option<NaiveDateTime>,
  pub updated_at: Option<NaiveDateTime>,
}
```

The process of creating a struct was automated through a _**Makefile**_ [command](https://github.com/kraftaa/dracula/blob/a0ab6e859af0ef8bf7c71dbc8a837d49ea76938a/Makefile#L162). Here's how it works:

The **_create-model_** target in the _**Makefile**_ generates the necessary Rust files for each table. It begins by creating a _diesel.toml_ file for the table, which defines how the schema is printed.

The command then added the module for the table to the various locations in the project, including _**mod.rs**_ files for organizing the project’s code structure.

Using the _**diesel**_ _print-schema_ command, the schema for the specified table was fetched from the local Postgres database and saved to a Rust file.

The _**diesel_ext**_ crate then was used to generate the Rust struct for that table, which was placed into the appropriate module.

If there's a mismatch between our Rust struct and the database schema, the compilation fails, preventing runtime errors.

We also started pagination big tables with Diesel using _offset_ and _limit_ and our own struct and trait [RecordIter](https://github.com/kraftaa/dracula/blob/main/dracula_tasks/src/tasks/page_iter.rs) but later switched to SQLX.

**<span id="rust-sqlx">4.2 Rust + SQLX for Postgres</span>**

To handle large datasets from Postgres, we use SQLX (asynchronous SQL queries). SQLX is preferable over Diesel for streaming large tables, because:

_Async Support_
- SQLx is fully async and works well with Rust’s async ecosystem (Tokio), allowing for non-blocking database queries.
- Diesel, on the other hand, is synchronous (unless using Diesel Async, which is still less mature).

_Better Support for Dynamic Queries_
- SQLx allows to write raw SQL queries easily, making it simpler to implement flexible pagination logic.
- Diesel relies on a strong type system and query builder, which can make complex pagination queries harder to construct.

_Streaming Large Results_
- SQLx supports database _cursors_ and _fetch()_ for efficient streaming of paginated results, avoiding the need to load everything into memory at once.
- Diesel loads the entire result set into memory before paginating, which can be inefficient for large datasets.

It lets us read and stream queries efficiently, grabbing data in manageable chunks. This keeps memory usage down and prevents timeouts when processing huge datasets.
We also don't need to define table! macro and structs for the table, SQLX can define the struct to match the results of the SQL query. We still have some tables & structs for streaming tables, as they were defined before we figured out SQLX and were dealing with the pagination.


Here's a more complete example of how we implement streaming with SQLX:

```rust
use super::prelude::*;
pub use futures_util::stream::StreamExt;
use parquet::record::RecordWriter;
pub use sqlx::postgres::PgPool;

let pool = PgPool::connect(pg_uri).await?;
let wpc = sqlx::query_as::<sqlx::Postgres, WPCStreamRecord>(&query);

let wpc_stream = wpc.fetch(&pool);

let mut chunk_stream = wpc_stream.map(|fs| fs.unwrap()).chunks(5000);
while let Some(chunks) = chunk_stream.next().await {
    let mut row_group = pfile.next_row_group().unwrap();
    (&chunks[..])
      .write_to_row_group(&mut row_group)
      .expect("can't 'write_to_row_group' ...");
    pfile.close_row_group(row_group).unwrap();
}
```

This function fetches the table in batches and processes each batch as it goes. The approach prevents us from loading the entire dataset into memory at once, which would be a problem with very large tables.

**<span id="s3-parquet">4.3 S3 Integration and Parquet Output</span>**

The final step in the pipeline involves writing transformed data to AWS S3 in Parquet format. We use the parquet and _aws-sdk-s3_ crates in Rust to do this efficiently.

Here's how we implement this part of the pipeline:

```rust
let file = std::fs::File::create(path).unwrap();
let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();

{
  let mut row_group = pfile.next_row_group().unwrap();
  (&records[..])
    .write_to_row_group(&mut row_group)
    .expect("can't 'write_to_row_group' ...");
  pfile.close_row_group(row_group).unwrap();
}

pfile.close().unwrap();
```
[upload to S3](https://github.com/kraftaa/dracula/blob/a0ab6e859af0ef8bf7c71dbc8a837d49ea76938a/dracula_aws/src/aws.rs#L52):
```rust
pub async fn upload(
    path: PathBuf,
    bucket_name: &str,
    key: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let body = ByteStream::from_path(Path::new(&path)).await;
    let config = aws_config::defaults(BehaviorVersion::v2023_11_09())
        .region(REGION)
        .load()
        .await;
    println!("key {:?}", key);
    let client = S3Client::new(&config);
    let _ = client
        .put_object()
        .bucket(bucket_name)
        .key(key)
        .body(body.unwrap())
        .send()
        .await;
    println!("Uploaded file: {}", key);
    Ok(())
}
```

This approach lets us efficiently write data to Parquet format and upload it directly to S3.

**<span id="parallelism">5. Parallelism and Task Management</span>**

One area where Rust really great at is parallel data processing. Our ETL pipeline needs to handle large volumes of data efficiently, and Rust's concurrency model helps us do this without the complexity and overhead of frameworks like Spark.

**<span id="asynchronous-tokio">5.1 Asynchronous Data Processing with Tokio</span>**

We use Tokio, an asynchronous runtime for Rust to run tasks concurrently in Tokio runtime: 

```rust
tokio::task::spawn(async move {
  upload(dracula_file.into(), BASE_PATH, path.as_str())
    .await
    .expect("upload file to s3 from all - must work");
});
```
This approach lets us efficiently use multiple CPU cores without the headache of manually managing threads.

**<span id="parallel-rayon">5.2 Parallel Data Processing with Rayon</span>**

We set up several threads with Rayon ThreadBuilder to expedite data processing:
```rust
::rayon::ThreadPoolBuilder::new()
        .num_threads(2)
        .build_global()
        .unwrap();
```
We need strict control over parallelism (to limit CPU usage), so we keep this definition in our _main()_ function.

then it used in all files as 
```rust
    let records: Vec<PurchaseOrderTaskRecord> = purchase_orders
        .par_iter()
        .filter(|po| {
```
Where _par_iter()_ enables parallel iteration over purchase_orders, distributing work across multiple threads.
Each thread processes part of the collection independently (e.g., applying the _.filter()_ in parallel).
Rayon's thread pool manages execution, using up to _num_threads(2)_ threads because of our _ThreadPoolBuilder_ setup.

**<span id="memory-management">5.3 Memory Management Considerations</span>**

When processing large datasets, memory management becomes super important. Rust's ownership model helps us control memory usage precisely:
```rust
let mut chunk_stream = wpc_stream.map(|fs| fs.unwrap()).chunks(5000);
while let Some(chunks) = chunk_stream.next().await {
  // processing chuncks 
}
```
We only load and process a small batch (5000 records) at a time, preventing excessive memory consumption. This approach enables handling arbitrarily large datasets while maintaining near-constant memory usage—assuming we don’t retain previous batches. Because each batch is processed and then dropped before fetching the next one, memory usage remains stable rather than growing indefinitely.

**<span id="complex-types">6. Handling Complex Data Types</span>**

Real-world data is rarely clean, and any ETL system needs to handle various complex data types. Rust’s rich type system makes it an excellent choice for managing these challenges in our pipeline, ensuring that our data transformation processes are both efficient and reliable.

**<span id="decimal-finance">6.1 Numeric Precision: Decimal & Financial Data</span>**

One of the primary challenges when working with financial data is maintaining precision. Using floating-point numbers for currency introduces the risk of rounding errors, which can be disastrous in financial calculations. Rust’s rust_decimal crate provides a reliable solution by offering fixed-point decimal arithmetic.

For example, when dealing with conversion rates or other financial metrics, we use Decimal to preserve precision:

```rust
use rust_decimal::Decimal;

// Define a struct for an order with financial data
#[derive(Queryable, Debug, sqlx::FromRow)]
pub struct Currency {
    pub id: i32,
    pub currency: Option<String>,
    pub conversion_rate: Option<BigDecimal>,

}

let records: Vec<CurrencyRecord> = currencies
  .iter()
  .map(|c| {

  }
  // Then calculate conversion_rate precisely
  let conversion_rate: c
    .conversion_rate
    .as_ref()
    .unwrap()
    .to_f64()
    .expect("big decimal rate"),
```
By using _Decimal_ instead of floating-point types, we avoid common pitfalls and ensure that the data transformations in our pipeline are accurate.

<span id="date-time">6.2 Working with Dates & Time Zonesg</span>

Handling dates and times is another crucial part of any ETL pipeline. Across different systems, the formatting and time zone handling can vary significantly. Rust’s chrono crate helps manage these complexities efficiently.

For instance, parsing date strings and manipulating them is straightforward in Rust:

```rust
use chrono::{DateTime, NaiveDateTime, NaiveDate, Utc};

// Parse a date string from an external system
let default_date =
  NaiveDateTime::parse_from_str("2010-01-01 00:00:00", "%Y-%m-%d %H:%M:%S").unwrap();

// Create  NaiveDate from calculated year/month/day
NaiveDate::from_ymd_opt(year, *month, last_day);
```
chrono allows us to seamlessly handle various date formats and manipulate them consistently. This ensures that data from different sources is interpreted correctly and aligned with our system’s time zone expectations

**<span id="date-jsonb-array">6.3 Structuring Complex Data: JSONB & Arrays</span>**

In PostgreSQL, many descriptive fields are stored using jsonb or ARRAY formats. While Rust allows us to read and manipulate these data types, storing them in Parquet presents some challenges. Since Parquet doesn’t support jsonb or ARRAY types natively, we need to serialize them to strings when writing to Parquet:

```rust
pub justifications: Option<Vec<String>>,
pub options: Option<serde_json::Value>,
```

This conversion to strings introduces an additional serialization step, which can impact performance when querying the data. For example, storing complex structures as serialized strings means that we’ll need to parse them back into their original format when querying, adding overhead to the analysis.

While we can manage and work with jsonb and ARRAY in Rust, these conversions create challenges, especially when trying to maintain the original structure and ensure optimal performance in downstream processes.

Handling complex data types is a key part of any ETL pipeline. Rust’s strong typing and libraries like rust_decimal and chrono make it a powerful choice for ensuring precision and consistency. However, when dealing with formats like jsonb or ARRAY, we face challenges with serialization and performance, requiring us to balance flexibility and efficiency.


**<span id="reflecting">7. Reflecting on the Project: What Went Right and What Didn't</span>**

Looking back, the project had its share of wins and challenges.

**<span id="rust-versions">7.1 Rust Versioning Challenges</span>**

One major headache was versioning. We couldn’t upgrade to the latest stable Rust version due to compatibility issues with dependencies. As a result, we were stuck on Rust 1.69 for over two years. This prevented us from using many modern Rust features, such as:

#[derive(Default)] on Enums
Improved error messages for the borrow checker
Stabilized std::sync::Mutex::unlock()

In hindsight, we might have made different architectural decisions or invested more effort into maintaining our own forks of critical dependencies.

**<span id="orm-pros-cons">7.2 The Pros and Cons of Diesel ORM</span>**

Diesel offered strong type safety and great query performance but came with challenges:

Auto-generated schema pulled unnecessary columns, impacting query efficiency.
Complex joins and advanced PostgreSQL features required raw SQL.

We solved these by defining smaller schema sets and keeping them in sync with the database changes.

```rust
table! {
  notes (id) {
    id -> Int8,
    title -> Nullable<Text>,
    body -> Nullable<Text>,
    status -> Nullable<Varchar>,
    // Note: we could omit columns we don't need
  }
}
```

This reduced data transfer overhead and increased efficiency.


**<span id="operational-complexity">7.3 Operational Maintenance and Monitoring of a Custom ETL</span>**

Building our own ETL pipeline came with significant operational overhead, including challenges in deployment, monitoring, and error handling. Here’s how we approached these areas:

_Deployment Complexity_: We had to build custom CI/CD pipelines to handle the deployment of our Rust binaries, which added a layer of complexity to the process.

_Monitoring and Observability_: Initially, we relied on logs to monitor the system. Over time, we implemented Prometheus to collect performance metrics, although we later phased it out in favor of more streamlined logging. We also used structured logging with the tracing crate to capture rich metadata, making it easier to trace and debug the ETL processes. We integrated Sentry for error reporting, allowing us to monitor errors in real time and get detailed insights into our pipeline.

Example of structured logging with Sentry:

```rust
let _guard = sentry::init((
  "https://id@id2.ingest.sentry.io/id4?timeout=10,verify_ssl=0",
  sentry::ClientOptions {
    release: sentry::release_name!(),
    environment: Some("production".into()),
    ..Default::default()
  },
));

pretty_env_logger::init();

info!("file {} has been uploaded", file_name);
```
This setup allows us to capture detailed insights into the ETL pipeline, helping us monitor performance, identify errors, and understand system behavior in real time.

_Error Handling and Retries_: We custom-built retry mechanisms to handle various failure scenarios, ensuring robustness in the pipeline.

_Challenges with Diesel and Parquet_: Diesel’s error descriptions were sometimes vague, making debugging difficult when there were mismatches between the database schema and Rust models. Additionally, we had to work around Parquet’s lack of native support for certain types like UUID and bool, which required custom conversions.

For monitoring performance metrics, we initially integrated Prometheus, a powerful tool for collecting and querying real-time metrics. However, due to time constraints, we phased out Prometheus in favor of focusing on structured logs and other monitoring mechanisms. Despite this, we still maintain awareness of our pipeline health.

Despite these hurdles, our custom ETL pipeline delivered solid performance and stability, processing millions of records daily with minimal resource usage. The extra operational complexity was justified by the reliability and performance benefits.


**<span id="conclusion">8. Conclusion: Lessons Learned and Moving Forward</span>**

**<span id="takeways">8.1 Key Takeaways</span>**

This project was a fantastic learning experience, and we gained valuable insights into Rust's power for ETL pipelines. Looking ahead, we recognize that:

_Type Safety_: The Rust compiler’s checks saved us countless hours of debugging.

_Performance_: Rust provided clear performance benefits, leading to cost savings.

_Operational Complexity_: Custom solutions require a lot of ongoing work.

_Dependency Management_: Sticking to an older version of Rust caused friction.

We’re now transitioning to more modern tools like PostgreSQL and dbt, taking advantage of powerful cloud resources and reducing complexity. The Rust project remains a cornerstone in our team's development and knowledge. Moving forward, we’ll continue exploring new tools that balance performance, reliability, and ease of use.

**<span id="future">8.2 Future Directions</span>**

As we move away from the Rust-based ETL pipeline, we're exploring modern tools like PostgreSQL and dbt to simplify and optimize our workflows.

_Increased Instance Power_: With more powerful cloud resources, tools like PostgreSQL and dbt are now more effective.

_dbt's Evolution_: dbt has become a robust solution with features like version control, testing, and documentation that address many challenges we faced with the custom pipeline.

_PostgreSQL Updates_: Improvements like partitioning and parallel query execution provide scalability and enhanced performance.

_Growing Expertise_: Our team's deeper understanding of SQL and data modeling aligns perfectly with dbt's strengths, making it a natural fit for our future data transformation needs.

**The Value of the Rust Project**

The Rust-based ETL pipeline was a challenging yet incredibly rewarding experience. It taught us critical lessons in performance optimization, system design, and maintainability. While we’re moving away from Rust for ETL, the project remains an important part of our team’s journey and has shaped our approach to data engineering.

[Extra details to be added later](#)

<div id="hidden-description" style="display:none;">
  <p>this would be more info about ARC/RC/Mutex/runtimes</p>
</div>

<script>
  document.querySelector('a[href="#"]').addEventListener('click', function(e) {
    e.preventDefault();
    var description = document.getElementById('hidden-description');
    if (description.style.display === "none") {
      description.style.display = "block";
    } else {
      description.style.display = "none";
    }
  });
</script>