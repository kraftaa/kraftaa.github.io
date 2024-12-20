---
layout: post
title: "From Postgres to Athena: Optimizing Workflows with Rust, Parquet, and S3"
date: 2024-12-17
img: rust4.png
tags: [Rust, AWS, S3, Postgres]
---

!!! Work in progress, many additions coming !!!

## Problem:
This project began several years ago as a solution to a pressing need for providing data for company reporting in the absence of an established ETL process. The production data resided in a Postgres RDS database, but generating reports directly from the primary instance was not feasible. Doing so would have imposed additional load on the main application and required additional roles to handle live production data.

Moreover, we needed to perform complex computations and aggregations and store the processed results for subsequent use in reporting. While Postgres excels at handling transactional workloads, it posed significant challenges when tasked with heavy computations, aggregations, and data enrichment.

## Security Concerns:
I didn’t want to give direct access to the Postgres RDS instance to other services or users. Instead, I wanted a secure and controlled way to read data, transform it, and expose only selected results. Access was restricted to calls made only via a program (like an API call) for security.

## Performance Issues:
Running complex calculations directly on the Postgres instance each time the user was opening the report or filtering it was affecting query performance for other critical workloads.

## Operational Complexity:
Incorporating derived fields and merging data from multiple tables resulted in overly complex schemas for views and queries, making them increasingly difficult to manage and maintain. Additionally, several machine learning computations needed to be performed on the production data, but running these directly on live data was not feasible.

## Cost Concerns:
Scaling the Postgres instance to handle heavy ETL (Extract, Transform, Load) processes was considered expensive at that time.

# The Solution: ETL with Rust + Parquet + S3 + Glue + Athena

[//]: # (![AWS Glue]&#40;{{site.baseurl}}/assets/img/glue.jpeg&#41;)
<div style="display: flex; align-items: center; gap: 10px;">
  <img src="{{site.baseurl}}/assets/img/kube.png" alt="Kubernetes" style="height: 100px;">
  <img src="{{site.baseurl}}/assets/img/rust1.png" alt="Rust" style="height: 100px;">
  <img src="{{site.baseurl}}/assets/img/s3.png" alt="AWS S3" style="height: 100px;">
  <img src="{{site.baseurl}}/assets/img/glue.jpeg" alt="AWS Glue" style="height: 100px;">
  <img src="{{site.baseurl}}/assets/img/athena.png" alt="AWS Athena" style="height: 100px;">
</div>

Instead of performing everything within Postgres, I built an ETL pipeline with Rust, AWS S3, GLue and Athena. Here’s how it worked:

## Rust Program:

The program fetched data from Postgres, performed transformations (including derived fields and joins across tables), and saved the output in Parquet format.
Using Rust allowed me to optimize performance and maintain type safety by representing tables as Rust structs.
Rust's type-checking served as a robust safeguard for ensuring the integrity of production data. If the production system encountered any invalid values or NaNs, the Rust process would immediately detect the issue and send an error notification, helping to maintain data accuracy and reliability.

The Rust program was deployed in a Kubernetes environment using a Helm chart. The chart configured a service account with the appropriate role-based access to AWS services, including S3 and Glue. Additionally, the Helm chart utilized a Kubernetes secret to securely manage the connection credentials for the RDS instance, ensuring secure and efficient integration with the necessary resources.

Parquet Files on S3:

Transformed data was stored in an S3 bucket in a columnar Parquet format. This reduced storage costs and improved query efficiency.

AWS Glue + Athena:

AWS Glue was used to crawl the Parquet files on S3 and create metadata.
Athena provided a cost-efficient way to query the data using SQL.

Struct/Table Representation in Rust

I mapped each table from Postgres to a Rust struct to ensure type safety and to handle transformations effectively. Here’s an example:

#### For instance, assume I had two tables:

**Table 1: orders**

| id | user_id | amount | created_at |
|----|---------|--------|------------|
| 1  | 101     | 200.5  | 2024-01-01 |
| 2  | 102     | 450.0  | 2024-01-02 |

**Table 2: users**

| id  | name    | country |
|-----|---------|---------|
| 101 | Alice   | USA     |
| 102 | Bob     | Canada  |

To combine these tables and add calculated fields, the Rust program used the following structs:

```rust
// Table 1: Orders
// order.rs for Postgres diesel schema
table! {
    orders (id) {
        id -> Int4,
        user_id -> Nullable<Int4>,
        amount -> Nullable<BigDecimal>,
        created_at -> Nullable<Timestamp>,
        uuid -> Uuid,
    }
}
// orders.rs for the struct   
use uuid::Uuid;
use bigdecimal::BigDecimal;
use chrono::NaiveDateTime;
#[derive(Queryable, Debug)]
pub struct Order {
    pub id: i32,
    pub user_id: Option<i32>,
    pub amount: f64,
    pub created_at: Option<NaiveDateTime>,
    pub uuid: Uuid,
}

// Table 2: Users
// user.rs for Postgres diesel schema
table! {
    users (id) {
        id -> Int4,
        name -> Nullable<Varchar>,
        country -> Nullable<Varchar>,
        created_at -> Nullable<Timestamp>,
        email -> Nullable<Varchar>,
    }
}
// users.rs for the struct
#[derive(Queryable, Debug)]
pub struct User {
    pub id: i32,
    pub name: Option<String>,
    pub country: Option<String>,
    pub creted_at: Option<NaiveDateTime>,
    pub email: Option<String>,
}

// Combined Struct: in the task Combined Order combined_orders.rs
#[derive(ParquetRecordWriter)]
struct CombinedOrderRecord {
    order_id: i32,
    user_id: i32,
    user_name: String,
    country: String,
    amount: f64,
    amount_with_tax: f64,
    created_at: Option<NaiveDateTime>,
}

pub fn combined_orders(pg_uri: &str) -> (String, i64) {
    let conn = PgConnection::establish(pg_uri).unwrap();
    let orders_load = Instant::now();
    let orders = orders_dsl::orders.load::<Order>(&conn).unwrap();
    let users = users_dsl::users.load::<User>(&conn).unwrap();

    let parquet_records: Vec<CombinedOrderRecord> = orders
        .iter()
        .filter(|order| order.user_id.is_some())
        .map(|p| {
            CombinedOrderRecord {
                order_id: order.order_id,
                user_name: user.name.clone(),
                country: user.country.clone(),
                amount: order.amount,
                amount_with_tax: order.amount * (1.0 + tax_rate),  // Calculation
                created_at: order.created_at,
            }
        });
}

```
Here:

Order and User represent the data fetched from Postgres.
CombinedOrder combines fields from both tables and includes a derived field amount_with_tax.
This structured approach made the code cleaner and easier to maintain.
## ETL Workflow
#### Extract:
The Rust program connected to the Postgres RDS instance and read data from orders and users tables.

#### Transform:
Using the CombinedOrder struct, I combined and combined the data, e.g., calculating amount_with_tax.

#### Load:
Transformed data was written to S3 as Parquet files.

####  Query:
Using AWS Glue, I crawled the Parquet files to make them queryable. Athena was then used to query the data efficiently.

## Pros of This Approach
Improved Security:

Direct access to Postgres was eliminated. Only the ETL program had read access, improving security.
Performance Isolation:

The heavy computations were offloaded to the Rust program, so the Postgres instance could focus on serving transactional queries.
Cost Efficiency:

Parquet files on S3 are cheap to store and efficient to query. Scaling Postgres was no longer necessary for ETL workloads.
Type Safety:

Using Rust structs ensured type safety, reducing errors in transformations.
Ease of Querying:

By integrating with AWS Glue and Athena, I could query enriched data using SQL without additional infrastructure.
### Cons of This Approach
#### Additional Infrastructure:

Maintaining the Rust program, S3 buckets, and Glue crawlers adds complexity.
#### Latency:

Data in Athena is only as fresh as the last ETL run, so it may not be suitable for real-time use cases.
#### Initial Setup:

Writing and testing the Rust ETL pipeline required a significant upfront effort.
#### Conclusion
By moving ETL workloads to a Rust-based pipeline, I was able to address security concerns, reduce operational complexity, and optimize costs. Postgres remained focused on its core transactional role, while combined data was efficiently stored and queried using modern tools like S3 and Athena.

This approach can be a template for teams looking to offload heavy ETL processes without burdening their databases.