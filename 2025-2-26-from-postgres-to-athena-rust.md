---
layout: post
title: "From Postgres to Athena: new version"
date: 2024-12-17
img: rust3.png
tags: [Rust, AWS, S3, Postgres]
---

Building a Cloud-Native ETL with Rust: A Retrospective

## Table of Contents
- [1. Data Warehouses](#data-warehouses)
  - [1.1. Security](#security)
  - [1.2. Performance](#performance)
  - [1.3 Operational Complexity](#complexity)
- [2. Why Rust](#why-rust)
  - [2.1. The Context and Alternatives](#context)
  - [2.2 Type Safety All the Way Down](#type-safety)
  - [2.3 Performance Considerations](#preformance-rust)
- [3. A Homemade Cloud-Native ETL Pipeline](#etl)
  - [3.1 Rust + Diesel for Postgres Pagination](#rust-diesel-pagination)
  - [3.2 Rust's Type Safety in the ETL Process](#rust-type-safety)
  - [3.3 S3 Integration and Parquet Output](#s3-parquet)
  - [3.3 S3 Integration and Parquet Output](#s3-parquet)
- [4. Reflecting on the Project: What Went Right and What Didn't](#reflecting)
  - [4.1 Rust Versioning Challenges](#rust-versions)
  - [4.2 The Pros and Cons of Diesel ORM](#orm-pros-cons)
  - [4.3 Operational Complexity with a Homemade ETL](#operational-complexity)
- [5. Parallelism and Task Management](#parallelism)
  - [5.1 Parallel Data Processing with Tokio](#parallel-tokio)
  - [5.2 Memory Management Considerations](#memory-management)
- [6. Handling Complex Data Types](#complex-types)
  - [6.1 Decimal Handling for Financial Data](#decimal-finance)
  - [6.2 Date and Time Handling](#date-time)
- [7. Monitoring and Observability](#monitoring)
  - [7.1 Structured Logging](#logging)
  - [7.2 Metrics and Alerting](#logging)
- [8. Conclusion: Lessons Learned and Moving Forward](#conclusion)
  - [8.1 Key Takeaways](#takeways)
  - [8.2 Future Directions](#future)



In this post, I'll walk you through a cloud-native ETL pipeline built using Rust. Over the years, I've worked on various data engineering projects, and this one stands out due to the challenges and decisions we made. From integrating with Postgres to writing to Parquet files on AWS S3, this project centered around performance, type safety, and minimizing operational complexity. Let's break down the major considerations and how we arrived at our architecture.

[//]: # (## 1. Data Warehouses )
## <span id="data-warehouses">1. Data Warehouses</span>
   
   Choosing the Right Backend
   When building a cloud-native ETL pipeline, choosing the right data warehouse to store and process your data is crucial. Here are the key factors we focused on:

###  <span id="security">1.1. Security</span>

   Security is paramount in our design. We ensure that all data transfers are encrypted and adhere to industry-standard security practices for both storage and access control. Using cloud-native solutions like AWS S3 helps us integrate best practices for encryption and access management seamlessly.
   For our ETL pipeline, we implement security measures at multiple levels:

Transport Layer Security: All data transferred between our ETL components and storage systems (Postgres, S3) uses TLS encryption.
IAM Role-Based Access: We leverage AWS IAM roles with the principle of least privilege, ensuring components only have access to the resources they absolutely need.
Data Encryption: We implement server-side encryption for data at rest in S3, using AWS KMS to manage encryption keys.
Secrets Management: Database credentials and API keys are stored in AWS Secrets Manager, never hardcoded.

These measures combine to create a defense-in-depth approach to securing our data pipeline.

###  <span id="performance">1.2. Performance</span>

Performance is essential when dealing with large data pipelines. We design our data flow to handle high-volume data efficiently. By optimizing our Postgres queries and leveraging Rust's parallelism capabilities, we ensure quick data processing. Rust's low-level memory control allows us to minimize overhead during batch processing.
Our performance optimization strategies include:

Efficient Pagination: We implement cursor-based pagination to efficiently process large datasets from Postgres without running into memory constraints.
Parallel Processing: Rust's concurrency model allows us to process multiple chunks of data simultaneously.
Columnar Data Format: Using Parquet as our output format significantly improves storage efficiency and query performance for downstream analytics.
Query Optimization: We use database indexes effectively and design queries to minimize unnecessary data retrieval.

The following code demonstrates our approach to pagination:
rustCopyfn paginate(connection: &PgConnection, offset: i64, limit: i64) -> QueryResult<Vec<YourModel>> {
use crate::schema::your_table::dsl::*;

    your_table
        .limit(limit)
        .offset(offset)
        .load::<YourModel>(connection)
}
This approach allows us to process millions of records efficiently without overwhelming system memory.

###  <span id="complexity">1.3 Operational Complexity</span>


Managing an ETL pipeline can quickly become overwhelming, especially when scaling. We minimize operational complexity by leveraging Rust's type safety. Rust's ability to catch errors at compile-time allows us to avoid runtime exceptions, streamlining maintenance and reducing the risk of issues in production.
In a traditional ETL pipeline built with a dynamically typed language like Python, many errors only surface at runtime - potentially after the pipeline has been running for hours. With Rust, we push error detection to compile-time, which means:

Fewer Production Incidents: Type mismatches and null pointer exceptions are caught before deployment.
Reduced Monitoring Overhead: Less time spent building extensive monitoring because the compiler catches many issues upfront.
Clearer Error Handling: Rust's Result and Option types force explicit handling of error cases, leading to more robust code.

This focus on type safety doesn't just improve reliability; it fundamentally changes how we maintain and operate the pipeline daily.

###  <span id="why-rust">2. Why Rust</span>
 
The Perfect Language for Cloud-Native ETL
   Rust wasn't a mainstream choice for ETL when we started this project. The data engineering world was dominated by Python, Scala (with Spark), and specialized tools like dbt. Here's why we made the unconventional choice to use Rust and what other options we considered.

###  <span id="context">2.1. The Context and Alternatives</span>

   When we began this project, the data engineering landscape looked quite different:

Apache Spark: While powerful, Spark introduced significant operational complexity and resource overhead that didn't fit our relatively modest data volumes (tens of GBs rather than TBs).
Python-based ETL: Tools like Airflow were gaining popularity, but we had concerns about type safety and performance with Python for our specific use case.
dbt: Was still in its early stages and lacked some features we needed for raw data extraction and transformation.

We needed something lightweight yet powerful, with high performance and strong type safety. Rust emerged as an unconventional but promising candidate.

###  <span id="type-safety">2.2 Type Safety All the Way Down</span>

Unlike languages like Python, where runtime errors are common, Rust ensures type safety from the application layer all the way to table definitions. By pushing error-handling to compile-time, we drastically reduce the chances of runtime failures.
Consider how we define our data models in Rust:
rustCopyuse diesel::Queryable;
use serde::{Deserialize, Serialize};

#[derive(Queryable, Serialize, Deserialize)]
pub struct Order {
pub id: i32,
pub customer_id: i32,
pub order_date: chrono::NaiveDateTime,
pub total_amount: rust_decimal::Decimal,
pub status: String,
}
This definition serves multiple purposes:

It maps directly to our Postgres table through Diesel's ORM
It enforces type safety when reading data from the database
It validates data before serialization to Parquet

The compiler ensures that we handle all potential type mismatches, null values, and conversion errors. This level of safety is simply not available in dynamically typed languages.

###  <span id="performance-rust">2.3 Performance Considerations</span>


Rust isn't just safe; it's also incredibly fast. We deal with large datasets, and Rust's performance is unparalleled in data processing tasks. Moreover, it allows us to create small executables with minimal memory overhead, perfect for cloud environments.
Our ETL workloads process millions of records daily, and Rust's performance characteristics provide several advantages:

Low Memory Overhead: Rust's lack of garbage collection means predictable memory usage patterns.
CPU Efficiency: Batch processing is CPU-intensive, and Rust's zero-cost abstractions mean we can process more data with less compute resources.
Small Binaries: Our compiled ETL applications are typically under 10MB, making deployment and scaling quick and efficient.

When processing time-sensitive data, these performance benefits translate directly to business value - fresher data for analysis and decision-making.
2.4 The Challenges of Working with Rust
This section wouldn't be complete without acknowledging the difficulties we faced. Working with Rust wasn't always smooth sailing, and these challenges should be considered by anyone contemplating a similar approach.
While Rust's strengths were apparent, working with its ownership and borrowing rules was challenging at times. Handling large data structures and managing memory efficiently required some adjustment. But in the end, the resulting performance and safety justified these hurdles.
Specific pain points included:

Steep Learning Curve: The ownership model took months for our team to fully internalize.
Limited Library Ecosystem: While growing rapidly, Rust's ecosystem for data processing was less mature than Python's or Java's when we started.
Compile Times: Large Rust projects can suffer from slow compilation, which impacted developer productivity.
Hiring Challenges: Finding engineers with Rust experience was significantly harder than finding those familiar with Python or Java.

Despite these challenges, we remain convinced that Rust was the right choice for our specific use case. The benefits in production have far outweighed the development difficulties.

##  <span id="etl">3. A Homemade Cloud-Native ETL Pipeline</span>

   Our ETL pipeline runs seamlessly on AWS infrastructure. Here's a breakdown of how it works:

###  <span id="rust-diesel-pagination">3.1 Rust + Diesel for Postgres Pagination</span>

   To handle large datasets from Postgres, we use Diesel, a Rust ORM. Diesel allows us to paginate queries efficiently, fetching data in manageable chunks. This reduces memory usage and prevents timeouts when processing extensive data.
   Let's look at a more complete example of how we implement pagination with Diesel:
   rustCopyuse diesel::prelude::*;
   use diesel::pg::PgConnection;
   use crate::models::{Order};
   use crate::schema::orders::dsl::*;

fn fetch_orders_in_batches(
connection: &PgConnection,
batch_size: i64,
process_batch: impl Fn(Vec<Order>)
) -> QueryResult<()> {
let total_orders = orders.count().get_result::<i64>(connection)?;
let mut offset = 0;

    while offset < total_orders {
        let batch = orders
            .limit(batch_size)
            .offset(offset)
            .load::<Order>(connection)?;
        
        process_batch(batch);
        offset += batch_size;
    }
    
    Ok(())
}
This function fetches orders in batches, processing each batch as it goes. The approach prevents us from loading the entire dataset into memory at once, which could cause issues with very large tables.
Diesel also provides strong type checking between our Rust code and the database schema:
rustCopy// Schema definition generated by diesel
table! {
orders (id) {
id -> Integer,
customer_id -> Integer,
order_date -> Timestamp,
total_amount -> Numeric,
status -> Text,
}
}

// Our model must match this schema
#[derive(Queryable)]
pub struct Order {
pub id: i32,
pub customer_id: i32,
pub order_date: chrono::NaiveDateTime,
pub total_amount: rust_decimal::Decimal,
pub status: String,
}
If there's a mismatch between our Rust struct and the database schema, the compilation fails, preventing runtime errors.

###  <span id="rust-type-safety">3.2 Rust's Type Safety in the ETL Process</span>

Rust's type system is invaluable in ensuring data integrity throughout the pipeline. From fetching data from Postgres to writing it into Parquet, we validate data structures at compile-time, ensuring each step is correct before running the pipeline.
A key aspect of our ETL process is transforming data between formats. Here's how we handle the transformation from our database model to our Parquet output model:
rustCopyuse crate::models::{Order, OrderParquet};

fn transform_orders(orders: Vec<Order>) -> Vec<OrderParquet> {
orders.into_iter().map(|order| {
OrderParquet {
order_id: order.id,
customer_id: order.customer_id,
order_date: order.order_date.date().to_string(),
total_amount_cents: (order.total_amount * rust_decimal::Decimal::from(100)).to_i64().unwrap_or(0),
status: order.status,
// Additional derived fields
is_completed: order.status == "COMPLETED",
order_year: order.order_date.date().year(),
order_month: order.order_date.date().month() as i32,
}
}).collect()
}
The compiler ensures that every field is properly accounted for. If we change the structure of OrderParquet, we'll get compile-time errors in all the places that create or use that struct, ensuring we don't miss any updates.

###  <span id="s3-parquet">3.3 S3 Integration and Parquet Output</span>

The final step in the pipeline involves writing transformed data to AWS S3 in Parquet format. We leverage the parquet and aws-sdk-s3 crates in Rust to perform this efficiently.
Here's how we implement this part of the pipeline:
rustCopyuse parquet::file::writer::{FileWriter, SerializedFileWriter};
use parquet::schema::parser::parse_message_type;
use aws_sdk_s3::{Client, Region, config};
use aws_sdk_s3::model::ObjectCannedAcl;
use bytes::Bytes;
use std::io::Cursor;

async fn write_to_parquet_and_upload(
data: Vec<OrderParquet>,
s3_client: &Client,
bucket: &str,
key: &str
) -> Result<(), Box<dyn std::error::Error>> {
// Define Parquet schema
let schema = parse_message_type(
"message schema {
required INT32 order_id;
required INT32 customer_id;
required BINARY order_date (UTF8);
required INT64 total_amount_cents;
required BINARY status (UTF8);
required BOOLEAN is_completed;
required INT32 order_year;
required INT32 order_month;
}"
).unwrap();

    // Create in-memory buffer
    let mut buffer = Vec::new();
    let cursor = Cursor::new(&mut buffer);
    
    // Create Parquet writer
    let mut writer = SerializedFileWriter::new(cursor, schema, Default::default()).unwrap();
    
    // Write rows
    let mut row_group_writer = writer.next_row_group().unwrap();
    
    // ... Write column data for each field using appropriate column writers ...
    
    row_group_writer.close().unwrap();
    writer.close().unwrap();
    
    // Upload to S3
    s3_client.put_object()
        .bucket(bucket)
        .key(key)
        .body(Bytes::from(buffer))
        .acl(ObjectCannedAcl::BucketOwnerFullControl)
        .content_type("application/octet-stream")
        .send()
        .await?;
    
    Ok(())
}
This approach allows us to efficiently write data to Parquet format and upload it directly to S3 without needing to write temporary files to disk.

##  <span id="reflecting">4. Reflecting on the Project: What Went Right and What Didn't</span>


   Looking back, the project had its share of wins and challenges.

###  <span id="rust-versions">4.1 Rust Versioning Challenges</span>

   One significant obstacle was versioning. We were unable to upgrade to the latest stable Rust version due to compatibility issues with dependencies. This meant that certain advanced features were unavailable, slowing down development at times.
   Specifically, we got stuck on Rust 1.42 for over a year because of incompatibilities between the aws-sdk-s3 crate and newer Rust versions. This prevented us from using many modern Rust features, including:

Async trait methods
The ? operator in more contexts
Various syntax improvements and standard library additions

This situation created real friction for our development team. New hires familiar with modern Rust would get frustrated by our inability to use features they considered standard. Documentation and examples from the community often wouldn't work for us without modification.
Had we known about these versioning challenges in advance, we might have made different architectural decisions or invested more in maintaining our own forks of critical dependencies.
4.2 The Pros and Cons of Diesel ORM

###  <span id="orm-pros-cons">4.2 The Pros and Cons of Diesel ORM</span>


Diesel was largely a great choice, but its automatic schema generation sometimes caused issues, pulling unnecessary columns from Postgres. We mitigated this by defining smaller Diesel schemas, ensuring only the required data was fetched.
The benefits of Diesel included:

Strong type safety between database and code
Excellent query performance
Compile-time SQL verification

However, we encountered several challenges:

The auto-generated schema pulled ALL columns from tables, resulting in inefficient queries
Complex joins and advanced PostgreSQL features required dropping down to raw SQL
Migration tooling was less mature than alternatives like Flyway or Liquibase

Our solution was to create custom, smaller schema definitions that only included the columns we needed:
rustCopytable! {
orders_minimal (id) {
id -> Integer,
customer_id -> Integer,
status -> Text,
// Note: We omit other columns we don't need
}
}
This approach improved query performance by reducing the amount of data transferred from the database, but required manual maintenance whenever the database schema changed.
4.3 Operational Complexity with a Homemade ETL

###  <span id="operational-complexity">4.3 Operational Complexity with a Homemade ETL</span>


While the custom nature of our ETL pipeline gave us flexibility, it came with more maintenance overhead compared to managed services like dbt or Airflow. However, the trade-off for performance and customizability was worthwhile.
Specific operational challenges included:

Deployment Complexity: We built our own CI/CD pipeline using AWS CodePipeline to handle building and deploying Rust binaries.
Monitoring and Observability: Without built-in monitoring, we had to implement our own using AWS CloudWatch and custom metrics.
Error Handling and Retries: We built custom retry logic for various failure scenarios.
Scaling: Horizontal scaling required custom implementation rather than being provided out-of-the-box.

Despite these challenges, the performance and reliability benefits justified the additional operational work. Our ETL pipeline consistently processes millions of records daily with minimal resource usage and excellent stability.

###  <span id="parallelism">5. Parallelism and Task Management</span>

   One of the areas where Rust truly shines is in parallel data processing. Our ETL pipeline needs to handle large volumes of data efficiently, and Rust's concurrency model helps us achieve this without the complexity and overhead of frameworks like Spark.

###  <span id="parallel-tokio">5.1 Parallel Data Processing with Tokio</span>

   We leverage Tokio, an asynchronous runtime for Rust, to process data in parallel:
   rustCopyuse tokio::task;
   use futures::stream::{StreamExt};

async fn process_data_in_parallel(data: Vec<Order>, batch_size: usize) -> Vec<OrderParquet> {
let results = futures::stream::iter(data.chunks(batch_size))
.map(|chunk| {
let chunk = chunk.to_vec();
task::spawn(async move {
transform_orders(chunk)
})
})
.buffer_unordered(10) // Process up to 10 chunks in parallel
.collect::<Vec<_>>()
.await;

    // Combine results and handle any errors
    results.into_iter()
        .filter_map(|res| res.ok())
        .flatten()
        .collect()
}
This approach allows us to efficiently utilize multiple CPU cores without the complexity of manually managing threads. The buffer_unordered method ensures we don't overwhelm the system by limiting the number of concurrent tasks.

###  <span id="memory-management">5.2 Memory Management Considerations</span>


When processing large datasets, memory management becomes critical. Rust's ownership model helps us control memory usage precisely:
rustCopyfn process_large_dataset(connection: &PgConnection) -> Result<(), Box<dyn std::error::Error>> {
const BATCH_SIZE: i64 = 10_000;
let total_records = get_total_record_count(connection)?;

    for offset in (0..total_records).step_by(BATCH_SIZE as usize) {
        // Fetch just one batch at a time
        let batch = fetch_batch(connection, offset, BATCH_SIZE)?;
        
        // Process the batch
        let processed = process_batch(batch);
        
        // Write this batch and free memory before fetching the next batch
        write_batch_to_parquet(processed, format!("output_{}.parquet", offset))?;
        
        // Memory for batch and processed is automatically freed here as they go out of scope
    }
    
    Ok(())
}
This pattern ensures that we only keep a small portion of the dataset in memory at any given time, allowing us to process arbitrarily large datasets with constant memory usage.

###  <span id="complex-types">6. Handling Complex Data Types</span>

   Real-world data is messy, and any ETL system needs to handle a variety of complex data types. Our Rust ETL pipeline excels at this thanks to Rust's rich type system.
   6.1 Decimal Handling for Financial Data

###  <span id="decimal-finance">6.1 Decimal Handling for Financial Data</span>

   One of the challenges we faced was handling financial data, which requires decimal precision. Using floating-point numbers for currency is problematic due to precision issues. Rust's ecosystem provides excellent solutions:
   rustCopyuse rust_decimal::Decimal;
   use rust_decimal_macros::dec;

// Define a struct for an order with financial data
#[derive(Queryable)]
pub struct Order {
pub id: i32,
pub total_amount: Decimal,
pub tax_rate: Decimal,
}

// Calculate tax amount precisely
fn calculate_tax(order: &Order) -> Decimal {
// This handles precision correctly for financial calculations
order.total_amount * order.tax_rate / dec!(100)
}
The rust_decimal crate provides a Decimal type that offers exact decimal arithmetic, crucial for financial calculations. Unlike floating-point types, it doesn't suffer from issues like 0.1 + 0.2 != 0.3.

###  <span id="date-time">6.2 Date and Time Handling</span>

Another common challenge in ETL pipelines is handling dates and times across different systems:
rustCopyuse chrono::{DateTime, NaiveDateTime, NaiveDate, Utc};

// Parse a date string from an external system
fn parse_date(date_str: &str) -> Result<NaiveDate, chrono::ParseError> {
NaiveDate::parse_from_str(date_str, "%Y-%m-%d")
}

// Convert database timestamp to ISO format for output
fn format_timestamp_for_output(timestamp: NaiveDateTime) -> String {
DateTime::<Utc>::from_utc(timestamp, Utc).to_rfc3339()
}
The chrono crate provides comprehensive datetime handling capabilities, allowing us to parse, manipulate, and format dates and times consistently across our pipeline.

###  <span id="monitoring">7. Monitoring and Observability</span>


   A production ETL pipeline requires robust monitoring and observability. Our Rust-based approach includes comprehensive telemetry.
   7.1 Structured Logging

###  <span id="logging">7.1 Structured Logging</span>

   We use the tracing crate for structured logging throughout our pipeline:
   rustCopyuse tracing::{info, error, warn, span, Level};

fn process_batch(batch: Vec<Order>) -> Result<Vec<OrderParquet>, Error> {
let span = span!(Level::INFO, "process_batch", batch_size = batch.len());
let _guard = span.enter();

    info!("Starting batch processing");
    
    // If something goes wrong
    if batch.is_empty() {
        warn!("Empty batch received, nothing to process");
        return Ok(vec![]);
    }
    
    // Process the batch
    let result = transform_orders(batch);
    
    info!(processed_count = result.len(), "Batch processing complete");
    Ok(result)
}
This approach gives us detailed insights into the pipeline's operation, with structured metadata that can be analyzed programmatically.

###  <span id="metrics">7.2 Metrics and Alerting</span>


We also collect performance metrics to monitor the health of our pipeline:
rustCopyuse metrics::{counter, gauge, histogram};

fn record_batch_metrics(batch_size: usize, processing_time_ms: u64) {
// Count total records processed
counter!("records.processed").increment(batch_size as u64);

    // Record processing time
    histogram!("batch.processing_time_ms").record(processing_time_ms as f64);
    
    // Set gauge for current processing rate
    let records_per_second = if processing_time_ms > 0 {
        (batch_size as f64) / (processing_time_ms as f64 / 1000.0)
    } else {
        0.0
    };
    gauge!("processing.records_per_second").set(records_per_second);
}
These metrics are exported to CloudWatch, where we set up alerts for various conditions like processing delays, error rates, and abnormal data volumes.

###  <span id="conclusion">8. Conclusion: Lessons Learned and Moving Forward</span>

   Looking back, this project was a rewarding experience. We built a high-performance, secure, and type-safe ETL pipeline that operates efficiently in the cloud. However, we learned that there's no one-size-fits-all solution. The choice of tools often comes down to balancing complexity against functionality.

###  <span id="takeways">8.1 Key Takeaways</span>

   From our experience building and maintaining this ETL pipeline, several important lessons emerged:

Type Safety Pays Off: The investment in Rust's strict type system saved us countless hours of debugging production issues.
Performance Matters: For data-intensive applications, the performance benefits of a language like Rust translate directly to cost savings and improved data freshness.
Operational Complexity is Real: Building custom solutions requires significant investment in operational tooling and practices.
Dependency Management is Critical: Being stuck on older versions of Rust due to dependency issues created real friction for development.


###  <span id="future">8.2 Future Directions</span>

Going forward, we're interested in exploring ways to streamline the ETL process further while maintaining the flexibility and performance Rust offers. Additionally, as the data volume grows, it will be important to make the system more resilient and scalable.
Specific areas we're investigating include:

Stream Processing: Moving from batch to streaming for certain data flows
Container-Native Deployment: Leveraging Kubernetes for better scaling and resource utilization
Schema Evolution: Building more robust handling of schema changes across the pipeline
Dependency Improvements: Contributing back to the Rust ecosystem to improve the libraries we depend on

While our Rust-based ETL pipeline has served us well, the data engineering landscape continues to evolve. We remain committed to evaluating new approaches and technologies as they emerge, always with an eye toward balancing performance, reliability, and developer productivity.
The journey to build this cloud-native ETL pipeline has been challenging but incredibly rewarding. The decisions we made, while not always perfect, have resulted in a system that meets our needs for performance, reliability, and maintainability. We hope that sharing our experience helps others who are considering similar approaches for their data engineering needs.