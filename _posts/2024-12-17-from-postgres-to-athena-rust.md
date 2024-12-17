---
layout: post
title: "From Postgres to Athena: Optimizing Workflows with Rust, Parquet, and S3"
date: 2024-12-17
---
!!! Work in progress, many additions coming !!!

## Problem:
I had a Postgres RDS database holding production data. While Postgres is great for transactional workloads, I faced multiple challenges when trying to perform heavy computations, aggregations, and data enrichment:

## Security Concerns:
I didn’t want to give direct access to the Postgres RDS instance to other services or users. Instead, I wanted a secure and controlled way to read data, transform it, and expose only selected results. Access was restricted to calls made only via a program (like an API call) for security.

## Performance Issues:
Running complex calculations directly on the Postgres instance was affecting query performance for other critical workloads.

## Operational Complexity:
Adding derived fields and combining multiple tables led to bloated schemas and queries that were difficult to maintain.

## Cost Concerns:
Scaling the Postgres instance to handle heavy ETL (Extract, Transform, Load) processes was becoming expensive.

# The Solution: ETL with Rust + Parquet + S3 + Glue + Athena
Instead of performing everything within Postgres, I built an ETL pipeline in Rust. Here’s how it worked:

## Rust Program:

The program fetched data from Postgres, performed transformations (including derived fields and joins across tables), and saved the output in Parquet format.
Using Rust allowed me to optimize performance and maintain type safety by representing tables as Rust structs.

Parquet Files on S3:

Transformed data was stored in an S3 bucket in a columnar Parquet format. This reduced storage costs and improved query efficiency.

AWS Glue + Athena:

AWS Glue was used to crawl the Parquet files on S3 and create metadata.
Athena provided a cost-efficient way to query the enriched data using SQL.

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
struct CombinedOrder {
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

    let parquet_records: Vec<CombinedOrder> = orders
        .iter()
        .filter(|order| order.user_id.is_some())
        .map(|p| {
            CombinedOrder {
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
EnrichedOrder combines fields from both tables and includes a derived field amount_with_tax.
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
By moving ETL workloads to a Rust-based pipeline, I was able to address security concerns, reduce operational complexity, and optimize costs. Postgres remained focused on its core transactional role, while enriched data was efficiently stored and queried using modern tools like S3 and Athena.

This approach can be a template for teams looking to offload heavy ETL processes without burdening their databases.