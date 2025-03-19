---
layout: post
title: "Building a Cloud-Native ETL with Rust: A Retrospective"
date: 2024-12-17
img: rustacean-flat-happy.svg
tags: [Rust, AWS, S3, Postgres]
---


## Table of Contents
- [1. Problem](#problem)
- [2. Data Warehouses](#data-warehouses)
    - [2.1. Security](#security)
    - [2.2. Performance](#performance)
    - [2.3 Operational Complexity](#complexity)
- [3. Why Rust](#why-rust)
    - [3.1. The Context and Alternatives](#context)
    - [3.2 Type Safety](#type-safety)
    - [3.3 Performance Considerations](#preformance-rust)
    - [3.4 The Challenges of Working with Rust](#challenges-rust)
- [4. A Homemade Cloud-Native ETL Pipeline](#etl)
    - [4.1 Rust + Diesel for Postgres](#rust-diesel)
    - [4.2 Rust + SQLX for Postgres](#rust-sqlx)
    - [4.3 Rust's Type Safety in the ETL Process](#rust-type-safety)
    - [4.4 S3 Integration and Parquet Output](#s3-parquet)
- [5. Parallelism and Task Management](#parallelism)
    - [5.1 Asynchronous Data Processing with Tokio](#asynchronous-tokio)
    - [5.2 Parallel Data Processing with Rayon](#parallel-rayon)
    - [5.3 Memory Management Considerations](#memory-management)
- [6. Handling Complex Data Types](#complex-types)
    - [6.1 Decimal Handling for Financial Data](#decimal-finance)
    - [6.2 Date and Time Handling](#date-time)
    - [6.3 Jsonb and Array](#date-jsonb-array)
- [7. Monitoring and Observability](#monitoring)
    - [7.1 Structured Logging](#logging)
    - [7.2 Metrics and Alerting](#logging)
- [8. Reflecting on the Project: What Went Right and What Didn't](#reflecting)
  - [8.1 Rust Versioning Challenges](#rust-versions)
  - [8.2 The Pros and Cons of Diesel ORM](#orm-pros-cons)
  - [8.3 Operational Complexity with a Homemade ETL](#operational-complexity)
- [9. Conclusion: Lessons Learned and Moving Forward](#conclusion)
  - [9.1 Key Takeaways](#takeways)
  - [9.2 Future Directions](#future)

Hey there! 

Today I'm going to walk you through a cloud-native ETL pipeline we built using Rust. 
This project was very interesting both for the challenges we faced and the stuff we learned.
We were dealing with everything from Postgres integration to writing Parquet files on AWS S3, with a focus on performance, type safety, and keeping operational headaches to a minimum. 

Let's break it down.

<strong><span id="problem">1. Problem</span></strong>

This whole thing started a few years back when we needed a solution for company reporting without an established ETL process. Our production data lived in a Postgres RDS database, but pulling reports directly from the primary instance wasn't going to work - it would've put extra load on the main app and required additional roles to handle live production data.
Plus, we needed to run complex calculations and aggregations, then store those processed results for reporting later. 
Postgres is great for transactional workloads, but we hit some walls when it came to heavy computations and data enrichment, and we could not run ML computations on live data.
And we didn't want to denormalize the tables by storing all the calculated fields in Postgres.

<strong><span id="data-warehouses">2. Data Warehouses</span></strong>

Choosing the Right Backend

When you're building a cloud-native ETL pipeline, picking the right data warehouse is crucial. Here's what we focused on:

**<span id="security">2.1. Security</span>**

Security was non-negotiable in our design. We made sure all data transfers were encrypted and followed industry-standard security practices for both storage and access control. Going with cloud-native solutions like AWS S3 let us easily incorporate encryption and access management best practices.

For our ETL pipeline, we layered security at multiple levels:

_Transport Layer Security_: All data moving between our ETL components and storage systems (Postgres, S3) uses TLS encryption.

_IAM Role-Based Access_: We used AWS IAM roles with the principle of the least privilege - components only get access to what they absolutely need.

_Data Encryption_: We set up server-side encryption for data at rest in S3, with Amazon S3 managed keys.

_Secrets Management_: Database credentials and API keys live safely in Kubernetes secrets.

These measures combine to create a defense-in-depth approach that keeps our data pipeline secure.

**<span id="performance">2.2. Performance</span>**

We designed our data flow to handle high-volume data without slowing down our main application. By optimizing our Postgres queries and leveraging Rust's parallelism capabilities, we keep data processing quick and efficient. Rust's low-level memory control also helped minimize overhead during batch processing.

Our performance optimization definition includes:

_Efficient Streaming_: Streaming a data in chunks for the big tables.

_Parallel Processing_: Rust's concurrency model lets us process multiple chunks of data at the same time.

_Asynchronous Processing_: Rust's tokio run time model lets us process tasks asynchronously.

_Columnar Data Format_: Using Parquet as our output format dramatically improves storage efficiency and query performance for downstream analytics.

_Query Optimization_: We make effective use of database indexes and design queries to minimize unnecessary data retrieval.


**<span id="complexity">2.3 Operational Complexity</span>**

Managing an ETL pipeline can quickly become unmanageable, especially when while scaling up. We kept operational complexity in check by leaning on Rust's type safety.

In a traditional ETL pipeline built with something like Python, many errors only show up at runtime - potentially after the pipeline has been running for a while.
With Rust, we catch problems at compile-time, which means:

_Fewer Production Incidents_: Type mismatches and null pointer exceptions get caught before deployment, not propagating the wrong data into the reports.

_Less Monitoring Overhead_: We spend less time building extensive monitoring because the compiler catches many issues upfront.

_Clearer Error Handling_: Rust's Result and Option types force us to explicitly handle error cases, leading to more robust code.

This focus on type safety improves reliability and helps us to maintain our pipeline.

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

Unlike Python where runtime errors are implied, Rust ensures type safety from the application layer all the way to table definitions. By catching errors at compile-time, we dramatically reduce the chances of runtime failures.

Check out how we define our data models in Rust:

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
This model allows us to pick up only the fields we need, without loading all the table. 

[Placeholder:Click here for more details](#)

<div id="hidden-description" style="display:none;">
  <p>Placeholder: This is the hidden description that will appear when the link is clicked.</p>
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

This definition does multiple things at once:

It maps directly to our Postgres table through Diesel's ORM.

It enforces type safety when reading data from the database.

It validates data before serialization to Parquet

The compiler makes sure we handle all potential type mismatches, null values, and conversion errors. You can't get this level of safety with dynamically typed languages.

**<span id="performance-rust">3.3 Performance Considerations</span>**

Rust isn't just safe; it's blazing fast. We're dealing with large datasets, and Rust's performance is hard to beat for data processing tasks. Plus, it lets us create small executables with minimal memory overhead, which is perfect for cloud environments.

Our ETL workloads process millions of records every day, and Rust gives us several performance advantages:

_Low Memory Overhead_: No garbage collection means predictable memory usage patterns.

_CPU Efficiency_: Batch processing is CPU-intensive, and Rust's zero-cost abstractions mean we can process more data with fewer compute resources.

_Small Binaries_: Our compiled ETL applications are typically under 250MB, which makes deployment and scaling quick and efficient.

When we're processing time-sensitive data, these performance benefits translate directly to the fresher data for analysis and decision-making.

**<span id="challenges-rust">3.4 The Challenges of Working with Rust</span>**

Working with Rust came with its own set of challenges anyone considering a similar approach should know about.

Getting comfortable with its ownership and borrowing rules took some serious learning. Handling large data structures, managing memory efficiently and wrangling concurrency was sometimes tricky and challenging. But in the end, the performance and safety we got made those hardships worth it.

Some specific pain points:

_Steep Learning Curve_: It took our team months to fully wrap our heads around how to handle most types and the huge tables.

_Limited Library Ecosystem_: While growing fast, Rust's ecosystem for data processing wasn't as mature as Python's or Java's when we started.

_Compile Times_: Large Rust projects can be slow to compile, which hurt developer productivity. It also required different packages installation while running locally on Macos vs Kubernetes ubuntu pod.

_Compiling for Different Environment_: Testing Rust project on macOS and deploying it to Ubuntu server not always looked the same. macOS uses Clang as the default C/C++ compiler, when on Ubuntu we had to install or configure GCC by ourselves.

_Collaboration Challenges_: Finding engineers within the team with Rust experience is harder than finding engineers who know Python or Java.

_Maintaining local database_: In order to be able automatically create table! macro definition and a struct we had to have local copy of the table though we didn't need the data in it.

_Introducing changes_: As Rust can't create structs dynamically, each change in the database had to be addressed manually: if the column is removed from the table Rust panics because it's hardcoded in our model.

Despite these challenges, we're still convinced Rust was the right choice for us. The benefits in production have far outweighed the development difficulties.

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

The full code (condenced and without specific tables located [**here**](https://github.com/kraftaa/dracula)).

Here's how it works:

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

**<span id="rust-sqlx">4.2 Rust + SQLX for Postgres</span>**

To handle large datasets from Postgres, we use SQLX (asynchronous SQL queries). It lets us read and stream queries efficiently, grabbing data in manageable chunks. This keeps memory usage down and prevents timeouts when processing huge datasets.
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


**<span id="rust-type-safety">4.3 Rust's Type Safety in the ETL Process</span>**

Rust's type system is a great help for ensuring data integrity throughout the pipeline. From fetching data from Postgres to writing it into Parquet, we validate data structures at compile-time, making sure each step is correct before the pipeline even runs.

A key part of our ETL process is transforming data between formats. Here's how we handle the transformation from our database model to our Parquet output model:

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

**<span id="s3-parquet">4.4 S3 Integration and Parquet Output</span>**

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

When you're processing large datasets, memory management becomes super important. Rust's ownership model helps us control memory usage precisely:
```rust
let mut chunk_stream = wpc_stream.map(|fs| fs.unwrap()).chunks(5000);
while let Some(chunks) = chunk_stream.next().await {
  // processing chuncks 
}
```
We only load and process a small batch (5000 records) at a time, preventing excessive memory consumption. This approach enables handling arbitrarily large datasets while maintaining near-constant memory usage—assuming we don’t retain previous batches. Because each batch is processed and then dropped before fetching the next one, memory usage remains stable rather than growing indefinitely.

**<span id="complex-types">6. Handling Complex Data Types</span>**

Real data is sometimes messy, and any ETL system needs to handle all sorts of complex data types. Our Rust ETL pipeline handles this really well thanks to Rust's rich type system.

**<span id="decimal-finance">6.1 Decimal Handling for Financial Data</span>**

One challenge we faced was handling financial data, which requires decimal precision. Using floating-point numbers for currency is asking for trouble due to precision issues. Rust's ecosystem provides great solutions:
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

<span id="date-time">6.2 Date and Time Handling</span>

Another common challenge in ETL pipelines is handling dates and times across different systems:
```rust
use chrono::{DateTime, NaiveDateTime, NaiveDate, Utc};

// Parse a date string from an external system
let default_date =
  NaiveDateTime::parse_from_str("2010-01-01 00:00:00", "%Y-%m-%d %H:%M:%S").unwrap();

// Create  NaiveDate from calculated year/month/day
NaiveDate::from_ymd_opt(year, *month, last_day);
```
The chrono crate gives us comprehensive datetime handling capabilities, letting us parse, manipulate, and format dates and times consistently across our pipeline.

**<span id="date-jsonb-array">6.3 Jsonb and Array</span>**

Many of our descriptive fields were stored in PostgreSQL using jsonb or ARRAY formats.
While we were able to load and work with both jsonb and ARRAY in Rust, using:

```rust
pub justifications: Option<Vec<String>>,
pub options: Option<serde_json::Value>,
```

we encountered challenges when writing these columns to Parquet while preserving their original types.
To store them in Parquet, we had to convert them into String, effectively storing the entire ARRAY or jsonb blob as a serialized string. This introduced an additional parsing step when querying the data, impacting performance and usability.

**<span id="monitoring">7. Monitoring and Observability</span>**

A production ETL pipeline needs solid monitoring and observability. Our Rust-based approach provided us great tools to monitor the process.

**<span id="logging">7.1 Structured Logging</span>**

We use the tracing crate for structured logging throughout our pipeline:
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
This approach gives us detailed insights into how the pipeline is running, with structured metadata that can be analyzed programmatically.

**<span id="metrics">7.2 Metrics and Alerting</span>**

We also used to collect performance metrics with Prometheys an eye on the health of our pipeline, but later got rid of it as didn't have time to analyze it.

**<span id="reflecting">8. Reflecting on the Project: What Went Right and What Didn't</span>**

Looking back, the project had its share of wins and challenges.

**<span id="rust-versions">8.1 Rust Versioning Challenges</span>**

One major headache was versioning. We couldn't upgrade to the latest stable Rust version because of compatibility issues with dependencies. This meant we couldn't use certain advanced features, which slowed down development at times.
We were stuck on Rust 1.69 for over two years due to significant changes in many core packages. Upgrading to 1.80 would have required substantial effort, and since we don’t plan to support the project long-term, we chose to remain on 1.69.  This prevented us from using a bunch of modern Rust features, including:

- #[derive(Default)] on Enums:
- Improved Error Messages for Borrow Checker: More user-friendly error messages for common borrow-checker issues.
- Stabilized _std::sync::Mutex::unlock_: A method to explicitly unlock a Mutex without dropping it.
- Various syntax improvements and standard library additions.

If we'd known about these versioning challenges in advance, we might have made different architectural decisions or put more effort into maintaining our own forks of critical dependencies or simplifying most of the methods.


**<span id="orm-pros-cons">8.2 The Pros and Cons of Diesel ORM</span>**

Diesel was mostly a great choice, but its automatic schema generation sometimes caused issues, pulling unnecessary columns from Postgres. We worked around this by defining smaller Diesel schemas, making sure only the required data was fetched.

The benefits of Diesel included:

- Strong type safety between database and code
- Excellent query performance
- Compile-time SQL verification

However, we ran into several challenges:
- The auto-generated schema pulled ALL columns from tables, resulting in inefficient queries, so it needed to be manually adjusted.
- Complex joins and advanced PostgreSQL features sometimes required dropping down to raw SQL

Our solution was to create custom, smaller schema definitions that only included the columns we needed:

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

This approach improved query performance by reducing the amount of data transferred from the database, but it meant we had to manually maintain things whenever the database schema changed.

**<span id="operational-complexity">8.3 Operational Complexity with a Homemade ETL</span>**

While building our own ETL pipeline gave us flexibility, it definitely came with more maintenance overhead compared to managed services like dbt or Airflow. That said, the trade-off for performance and customizability made it worthwhile.

Some specific operational challenges we faced:

_Deployment Complexity_: We had to build our own CI/CD pipeline using our custom images to handle building and deploying Rust binaries.

_Monitoring and Observability_: Without built-in monitoring, we had to use logs and later prometheus for checking metrics.

_Error Handling and Retries_: We built custom retry logic for various failure scenarios.

_Diesel Errors Description_: Sometimes Diesel’s errors description could be better. In case of table/struct having mismatched order or types the error was just a blob of all info with the comment required by a bound in diesel::RunQueryDsl::load, which wasn’t very useful and required digging into the data.

_Parquet Support for different types_: When we created the program Parquet didn't support writing uuid, bool, so we had to convert them into String. Parquet still doesn't support Array and Json writing and unlikely would. Which implies we need to parse back the data in our views.

_Rust support for keywords_: We have to add  #[sql_name = "type"] to the table! macro for columns named _type_ and rename them into _type__.

Despite these challenges, the performance and reliability benefits justified the extra operational work. Our ETL pipeline consistently processes millions of records daily with minimal resource usage and excellent stability.


**<span id="conclusion">9. Conclusion: Lessons Learned and Moving Forward</span>**

Looking back, this project was a great experience. We built a high-performance, secure, and type-safe ETL pipeline that runs efficiently in the cloud. But we learned that there's no perfect solution for everyone. The choice of tools often comes down to balancing complexity against functionality.

**<span id="takeways">9.1 Key Takeaways</span>**

From our time building and maintaining this ETL pipeline, several important lessons stood out:

_Type Safety Pays Off_: The investment in Rust's strict type system saved us countless hours of debugging production issues.

_Performance Matters_: For data-intensive applications, the performance benefits of a language like Rust translate directly to cost savings and improved data freshness.

_Operational Complexity is Real_: Building custom solutions requires significant investment in operational tooling and practices.

_Dependency Management is Critical_: Being stuck on older versions of Rust due to dependency issues created real friction for development.

**<span id="future">9.2 Future Directions</span>**

Going forward, we're exploring new ETL options, including PostgreSQL and dbt, as our infrastructure and expertise have evolved. While the Rust-based ETL pipeline was a highly educational and satisfying project, we’ve decided to transition to more modern tools that align with our current needs and the advancements in the data engineering landscape.

Why the Shift?

_Increased Instance Power_: With more powerful hardware and cloud resources, we can now leverage tools like PostgreSQL and dbt more effectively.

_PostgreSQL Updates_: PostgreSQL has introduced significant improvements in performance, scalability, and features (e.g., partitioning, parallel query execution).

_dbt Updates_: dbt has become a powerful tool for transforming data in the warehouse, offering features like version control, testing, and documentation.

_Huge reduction of complexity_: reading data via dbt functionality removed questions about data updates, new columns introduction/removal etc

Our Knowledge Growth: Our team has gained deeper expertise in SQL, data modeling, and modern ETL practices, making tools like dbt a natural fit.

The Value of the Rust Project

The Rust-based ETL pipeline was a challenging but incredibly rewarding experience. It taught us valuable lessons about performance optimization, system design, and the importance of maintainability. While we’re moving away from Rust for ETL, the project remains a cornerstone of our team’s growth and expertise.

Looking Ahead

As the data engineering landscape continues to evolve, we’re staying open to new approaches and technologies. Our goal is to balance performance, reliability, and developer productivity while leveraging the best tools for the job. We hope sharing our experience helps others navigating similar challenges in their data engineering journeys.