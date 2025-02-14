---
layout: post
title: "From Postgres to Athena: Optimizing Workflows with Rust, Parquet, and S3"
date: 2024-12-17
img: rust3.png
tags: [Rust, AWS, S3, Postgres]
---

## Table of Contents
- [Problem](#problem)
- [The Solution](#the-solution)
    - [ETL](#etl)
    - [Rust Program](#rust-program)
      - [Members](#members)
      - [Schema](#schema)
      - [Tasks](#tasks)
      - [Streaming Tasks](#streaming-tasks)
      - [Thread Safety in Rust](#thread-safety-in-rust)
      - [RefUnwindSafe and UnwindSafe in Rust](#refunwindsafe-and-unwindsafe-in-rust)
      - [Streaming Tasks](#streaming-tasks)
      - [Parquet Writer](#parquet-writer)
    - [AWS](#aws)
      -  [Uploading to S3](#uploading-to-s3)
      -  [Crawler](#crawler)
    - [Executing the program](#executing-the-program)
- [Versions](#versions)
- [Summary](#summary)


## Problem:

This project began several years ago as a solution for providing data for company reporting in the absence of an established ETL process. The production data resided in a Postgres RDS database, but generating reports directly from 
the primary instance was not considered as an option. Doing so would have imposed additional load on the main application and required additional roles to handle live production data.

Moreover, we needed to perform complex computations and aggregations and store the processed results for subsequent use in reporting. While Postgres was great for handling transactional workloads, we faced some challenges when tasked with heavy computations and data enrichment.
And we didn't want to store all the calculated fields in Postgres which would denormalize the tables.

#### Security Concerns:

We did not want to give direct access to the Postgres RDS instance to other services or users. Instead, we wanted a secure and controlled way to read data, transform it, and expose only selected results. Access was restricted to calls made only via a program (API calls) for security.

#### Performance Issues:

Running complex calculations directly on the Postgres instance each time the user was opening the report or filtering it was affecting query performance for the main application.

#### Operational Complexity:

Incorporating derived fields and merging data from multiple tables resulted in overly complex schemas for views and queries, making them increasingly difficult to manage and maintain. Additionally, several machine learning computations needed to be performed on the production data, but running these directly on live data was not feasible.

#### Cost Concerns:

Scaling the Postgres instance to handle heavy _ETL (Extract, Transform, Load)_ processes was considered expensive at that time.


## The Solution:

#### ETL:

<div class="mermaid">
flowchart TD;
RustProgram[Rust Program] -->|Reads| PostgresRDS[PostgreSQL RDS];
RustProgram -->|Calculates & Aggregates| S3ParquetFiles[S3 Parquet Files];
AWS_GLUE[AWS Glue Crawler]-->|Crawls & Creates Schema| S3ParquetFiles[S3 Parquet Files];
S3ParquetFiles[S3 Parquet Files] -->|Tables via Glue Schema| AWSAthena[AWS Athena];
AWSAthena -->|Used in| Reports[Reports];

    %% Adding styles for clarity
    classDef process fill:#f9f,stroke:#333,stroke-width:2px;
    class RustProgram,PostgresRDS,S3ParquetFiles,AWS_GLUE,AWSAthena,Reports process;
</div>

Instead of performing everything within Postgres, we built **_an ETL pipeline with Rust, AWS S3, AWS Glue and AWS Athena._**


This **_Rust_** project was originally initiated by my colleague and Rust wizard, [**Xavier**](https://github.com/xrl). His guidance and expertise helped me not only get started with Rust but also truly appreciate its beauty, power, and advantages. Thanks to his mentorship, I’ve come to love working with Rust and have seen how it can transform complex workflows (or make it even more complex but blazing fast :wink: ).


### ETL overview:

**_Rust program:_**

The program fetched data from Postgres, performed transformations (including derived fields and joins across tables), and saved the output in Parquet format.
Using Rust allowed us to optimize performance and maintain type safety by representing tables as Rust _structs_.

Rust type-checking served as a safeguard for ensuring the integrity of production data. If the production system encountered any invalid values or _NaN_, the Rust process would immediately detect the issue and send an error notification, helping to maintain data accuracy and reliability.
The Rust program was deployed in a Kubernetes environment using a Helm chart. The chart configured a service account with the appropriate role-based access to AWS services, including S3 and Glue. Additionally, the Helm chart utilized a Kubernetes secret to securely manage the connection credentials for the RDS instance.

**_Parquet Files on S3:_**

Transformed data was stored in an S3 bucket in a columnar Parquet format. This reduced storage costs and improved query efficiency.

**_AWS Glue + Athena:_**

AWS Glue was used to crawl the Parquet files on S3 and create metadata.

Athena provided a cost-efficient way to query the data using SQL. Bear in mind that Athena doesn't create real tables or materialized views, it only creates a metadata and reads everything from the files, stored in S3.
The reports used Athena tables and views as the foundation for data visualization.
The cons of such approach were that it was possible to delete underlying file without getting any warnings/restrictions about dependant views, tables etc.
Athena also didn't provide indexing as it was just a querying tool with its own flavor PrestoDB SQL, it was lacking some Postgres methods and didn't allow recursive functions as well as true **_materialized views_**. It also didn't support ***CREATE TABLE LIKE*** or ***DELETE FROM*** or ***UPDATE***, but it allowed to give an access to query a table without a fear that the table would be dropped as it was just a file in s3.

AWS Glue provided a mechanism for partition indexing with the limitations: 
- only partition column could be used as an index
- only integer and strings could be used as an index

## Rust Program:

#### Members

Rust program workspace had the next members:
```rust
[workspace]
members = [
  "project_aws",
  "project_cli",
  "project_extra_source"
  "project_insert_data"
  "project_kube",
  "project_parquet",
  "project_schemas",
  "project_tasks",
  "project_partition_dates"
]
```

Why this project structure?

It was designed to allow the separation of _tasks_ and _crates_ in _Cargo.toml_. This separation enabled us to build and manage each component independently, avoiding unnecessary complexity and loading all the crates in once. It also provided better visibility into the performance of individual members, making it easier to track and optimize and fix.

<div class="mermaid">
flowchart TD;
    A["Rust Makefile"] -->|Creates table! macro & struct| B["project_schemas/tables & models"];
    B -->|Used in| C["project_tasks"];
    C -->|Also uses| D["project_parquet (props() for SerializedFileWriter Trait + prelude from mod.rs)"];
    C -->|Executes| E["project_cli"];
    E -->|Uploads data| S3["project_aws upload()"];
    E -->|Triggers AWS crawler| AWS["project_aws start_crawler()"];
</div>

#### Schema

Struct/Table Representation in Rust were in **_project_schemas_**:

In order to read the tables and perform some calculations and also to ensure type safety  I had to map each Postgres table to a corresponding Rust struct. Initially, this mapping was done manually, but later I discovered the powerful _**diesel_ext**_ crate (later [_**diesel_cli_ext**_](https://crates.io/crates/diesel_cli_ext)), which allowed me to automatically map the schema from Postgres to Rust structs. I still had to create diesel _table!_ macro definition which was automated with the help of _bash_ script. 
Running such a query:
```shell
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'orders';
```
was producing the result:
```shell
 column_name |          data_type          | is_nullable 
---------------------------------+------------------------
 id          | integer                     | NO
 active      | boolean                     | NO
 name        | character varying           | YES
 created_at  | timestamp without time zone | NO
 data        | jsonb                       | YES
 ...
```
This table description together with this [**bash script**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-table_macro-sh) would give diesel _table!_ definition.

```shell
table! {
    orders (id) {
        id -> Int4,
        active -> Bool,
        name -> Nullable<Varchar>,
        created_at -> Timestamp,
        data -> Nullable<Jsonb>,
    }
}
```
The process of creating a struct was automated through a _**Makefile**_ command. Here's how it worked:


The **_create-model_** target in the _**Makefile**_ generated the necessary Rust files for each table. It began by creating a _diesel.toml_ file for the table, which defined how the schema was printed.

The command then added the module for the table to the various locations in the project, including _**mod.rs**_ files for organizing the project’s code structure.

Using the _**diesel**_ _print-schema_ command, the schema for the specified table was fetched from the local Postgres database and saved to a Rust file.

The _**diesel_ext**_ crate then was used to generate the Rust struct for that table, which was placed into the appropriate module.


I created also a [_**template_task**_](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-template_task-rs) which was a blue-print for most tasks and used the _sed_ command to customize tasks' files, creating a corresponding task in the project.


Here’s the [**Makefile**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-create_model-rs)  command that does all of this.

This approach saved considerable time and streamlined the process, reduced the chance of errors with types/nullables by automating the mapping process.

Now I would rather put everything into combined bash script which would run over the predefined list of tables and create _table!_ macro definition and a corresponding struct with a task, but the existing approach worked well for years and I won't change it, as its life is coming to the end due to change in the infrastructure.
Here’s an example of some Postgres tables, corresponding structs and the task combining all of them with extra calculations:


For instance, assume we had several postgres tables:

_**Table 1: orders**_

| id | user_id | amount | created_at | uuid                                   |
|----|---------|--------|------------|----------------------------------------|
| 1  | 101     | 200.5  | 2024-01-01 | "aaaaaaaa-1111-3333-5555-oooooooooooo" |
| 2  | 102     | 450.0  | 2024-01-02 | "bbbbbbbb-2222-4444-6666-pppppppppppp" |

_**Table 2: users**_

| id  | name    | country | created_at | email              |
|-----|---------|---------|------------|--------------------|
| 101 | Alice   | USA     | 2023-01-01 | email1@example.com |
| 102 | Bob     | Canada  | 2023-01-02 | email2@example.com |

_**Table 3: products**_

| id | name     | quantity | created_at | approved | price |
|----|----------|----------|------------|----------|-------|
| 1  | product1 | 350      | 2023-01-10 | true     | 35.20 |
| 2  | product2 | 70       | 2023-01-20 | false    | 41.05 |
| 3  | product3 | 2        | 2023-01-20 | true     | 11.05 |

To combine these tables and add calculated fields, the Rust program used the following [**structs**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-tables_structs-rs) which looked like this:
```rust
// project_schemas/tables/orders_tl.rs for Postgres diesel schema
table! {
    orders (id) {
        id -> Int4,
        user_id -> Nullable<Int4>,
        amount -> Nullable<BigDecimal>,
        created_at -> Nullable<Timestamp>,
        uuid -> Uuid,
    }
}

// project_schemas/models/order.rs for the struct
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
```
where:

`use uuid::Uuid;`  imports the **Uuid** type from the uuid crate

`use bigdecimal::BigDecimal;` imports the **BigDecimal** type from the bigdecimal crate. **BigDecimal** is used to handle arbitrarily large or high-precision decimal numbers. It is commonly used in cases where floating-point precision is not enough.

`use chrono::NaiveDateTime;` imports the **NaiveDateTime** type from the chrono crate. **NaiveDateTime** is used to represent date and time without timezone information.

`#[derive(Queryable, Debug)]`

`Queryable:` This is a procedural macro from **diesel**. It automatically generates the necessary code to allow the struct to be used for querying data from the database. It means the **_Order_** struct can be used in diesel queries to map results from the database into instances of the struct.

`Debug:` This is another procedural macro, provided by Rust standard library. It automatically generates code to allow the struct to be printed in a human-readable form using `println!("{:?}", ...)`. It makes it easy to debug and print the struct in logs or console output.

The table and struct definitions were organized within the _**project_schemas**_ directory. This directory included the tables and models subdirectories, each housing the respective definitions. Additionally, a **_mod.rs_** file was used to list and manage all the tables and models for easier access and modularity.

```shell
project_schemas
└── src
   ├── tables
   ├── models
   └── lib.rs
└── Cargo.toml
```

[//]: # (<div class="mermaid">)

[//]: # (graph TD)

[//]: # (A[project_schemas])

[//]: # (A --> B[src])

[//]: # (B --> C[tables])

[//]: # (B --> D[models])

[//]: # (B --> E[lib.rs])

[//]: # (A --> F[Cargo.toml])

[//]: # (</div>)


#### Tasks

Then we had to combine all the data, add some calculations, write the result into parquet file and upload it to S3 into the designated busket/folder.

First we needed to bring modules and structs into the scope of our **_combined_orders.rs_** task.

```rust
use super::prelude::*;
use std::collections::HashMap;

use project_schemas::tables::{
    orders::dsl as orders_dsl, users::dsl as users_dsl,
    currencies::dsl as currencies_dsl, taxes::dsl as taxes,
};
```

What `use super::prelude::*;` does:

It imports all public items from the _**prelude**_ module defined in the parent module (**super**).
The `*` wildcard includes everything that is publicly available within the **_prelude_** module.

This is a common Rust pattern to create a _**prelude**_ module that contains frequently used imports, making them available to other parts of the codebase without needing repetitive use statements.

For example:

In the  [**prelude**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-task_mod-rs) module, there are imports like 
```rust
pub use std::time::Instant;
pub use diesel::prelude::*;
pub use bigdecimal::{BigDecimal, ToPrimitive};
... 
```

`pub mod prelude` makes the **prelude** module public.

`pub use std::time::Instant;` makes **Instant** available inside **prelude** and also public.

By doing `pub use super::prelude::*;`,  **_combined_orders.rs_** task can directly use these items without specifying them individually.


The line `pub use ::function_name::named;` refers to re-exporting the `named` macro from the external crate function_name.
My idea was to use it for generating a file name on the fly in order to provide a file name for writing it down as a parquet file (it was at the beginning of my Rust journey) however, `use` cannot be used to dynamically retrieve the name of a function and store it as file name with writing the result of the calculation at runtime.

In theory, what it does:

`function_name` crate provides a procedural macro to retrieve the name of the current function at compile-time in Rust. It is often used for logging, debugging, or tracing purposes.

`named` macro is a part of the `function_name` crate. It allows to annotate a function, so I can programmatically access its name as a string (as I was going to do).

When I apply `#[named]` to a function, it makes the name of the function accessible via a special variable _function_name_.
I can then log or use the function's name directly.

```rust
use function_name::named;

#[named]
fn example_function() {
    println!("Function name: {}", function_name!());
}

fn main() {
    example_function();
}
... 
# prints
# Function name: example_function

```

The _**prelude**_ model was inside `mod.rs` file which was in

```shell
project_tasks
├── src
   └── tasks 
         ├── mod.rs
         ├── combined_orders.rs
         └── .. other tasks
        
└── Cargo.toml
```
In `mod.rs` I had all tasks listed in such a manner:
```rust
mod combined_orders; 
pub use self::combined_orders::*;
```
What it did:

`pub use self::combined_orders::*;` re-exports all public items from the **_combined_orders_** module, making them available to other parts of the project that import this parent module.
This pattern is often used in a module hierarchy to provide a clean interface to submodules by selectively exposing their contents.

then in the task **_combined_orders.rs_**:
```rust
use std::collections::HashMap;
```
Which imports the `HashMap` type from the Rust standard library into scope.

```rust
use project_schemas::tables::{ ... };
```
This line imports specific modules from **_project_schemas::tables_** module, and it includes additional scoping and aliasing functionality.

What happens here:

`orders::dsl as orders_dsl` imports the dsl module from **_project_schemas::tables::orders_** and renames it as **_orders_dsl_**. I can now use it as **_orders_dsl_** throughout the file.
**_dsl_** stands for **_domain-specific language_**, which is a set of helper types, methods, or macros to construct _SQL_ queries using the **Diesel** ORM library for working with tables and columns in our postgres database.

Defining the struct for the output file:
```rust
#[derive(ParquetRecordWriter)]
struct CombinedOrderRecord {
    order_id: i32,
    user_id: Option<i32>,
    country: String,
    currency: String,
    conversion_rate: f64,
    user_email: Option<String>,
    amount: f64,
    amount_usd: f64,
    amount_with_tax: f64,
    created_at: Option<NaiveDateTime>,
}
```
Here `#[derive(ParquetRecordWriter)]` tells the Rust compiler to automatically implement the trait `ParquetRecordWriter` for the struct `CombinedOrderRecord`. 

The `ParquetRecordWriter` trait is a part of an external library `parquet_derive` which implements `#[proc_macro_derive(ParquetRecordWriter)]`  which defines a procedural macro that will be triggered by the `#[derive(ParquetRecordWriter)]` attribute applied to a struct or enum.
It will handle the input, fields/types and write the struct to a file in Parquet's binary format.

Then there is the task itself, `pub` which means it can be called outside the module,
the task takes as input a reference to a string (`&str`), representing PostgreSQL connection URI,  and returns a tuple of **String** and **bigint**.
The full task code is [**combined_orders.rs**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-combined_orders-rs)

```rust
pub fn combined_orders(pg_uri: &str) -> (String, i64) {
    let conn = PgConnection::establish(pg_uri).unwrap();
    let orders_load = Instant::now();
    let orders = orders_dsl::orders.load::<Order>(&conn).unwrap();
    trace!("load orders took: {:?}", orders_load.elapsed());
```
Here:

```shell
let orders = orders_dsl::orders.load::<Order>(&conn).unwrap();
```
This line uses **Diesel**, a Rust **ORM** (Object-Relational Mapping) library, to load data from the orders table in the database into a Rust struct (`Order`). Diesel ensures structs match database schema with implementing trait _**Queryable**_ for the struct. It generates the necessary code to convert a row from a database table into an instance of the struct. The struct fields must match the columns in the database table (in name and type).

**Diesel** uses DSLs to generate SQL queries and map the results to Rust types. The `users::dsl, orders::dsl` etc refer to the corresponding tables, and I'm giving them aliases (`orders_dsl, users_dsl`, ...) for convenience and loading, filtering using DSL methods.

`orders_dsl::orders**`

`orders_dsl` is the alias created for `orders::dsl`. **Diesel** automatically generates a `orders` variable (referring to the `orders` table in the database) within this DSL module, which represents the table in the database.

``.load::<Order>()`` is a Diesel method used to execute the query and load the results into a collection of Rust structs `Vec<Order>`.

`Order` is a Rust struct representing the schema of the `orders` table (i.e., it maps the columns of the `orders` table to fields in the `Order` struct).

`&conn` is a reference to a database connection, which is used to execute the query against the database. This connection is established using Diesel’s connection API ( _PgConnection_ for PostgreSQL).

`.unwrap()` is used to unwrap the _Result_ returned by ``load::<Order>()``. This method will either return the query results (if successful) or panic if there was an error.
Usually it is discouraged to use `unwrap` in production code unless I am certain that the query will succeed, as it causes the program to panic on an error.
We were using `unwrap` as wanted the program to panic and stop running, which would give us a clear sign that the data was not updated.
If I implemented it now I would rather use `expect` with the custom message but keep the panicking behaviour.
```shell
let orders = orders_dsl::orders
    .load::<Order>(&conn)
    .expect("Failed to load orders from the database");
```
Or this one to return an error and later handle the error in some way

```shell
let orders = match orders_dsl::orders.load::<Order>(conn) {
        Ok(orders) => orders,
        Err(e) => {
            eprintln!("Error loading orders: {}", e);
            return Err(e); // Return early with the error
        }
    };
```
Definitely NOT this one `unwrap_or_else` like this 
```shell
let orders = orders_dsl::orders
    .load::<Product>(&conn)
    .unwrap_or_else(|e| {
        eprintln!("Error loading orders: {}", e);
        Vec::new() // Return an empty vector as the fallback
    });
```
as here I will get an empty `Vec<Order>` into my data.

There is also an operator **_?_**  which propagates errors if any occur during the creation of the file avoiding unexpected panic.
Requires `Result/Option` return:
- If the operation returns _**Ok(value)**_, it extracts the value and continues execution.
- If the operation returns **_Err(error)_**, it propagates the error to the calling function.

Taking into account that the continuing the task without the connection to Postgres didn't make any sense, I have not considered this option.

Usually the `panic!()` was caused by changes in the underlying Postgres tables, like removed column, unexpected type etc. I couldn't dynamically construct a struct in Rust with Diesel - so if I had a column in my _table!_ macro definition and a struct but if `.load::<Order>` didn't find it - it resulted in panic.
In that case running the task which was loading this table further didn't make sense hence `panic!()` behaviour was justified.

I wanted to see how long it takes to load some tables, for that I had
```rust
let users_load = Instant::now();
let users = users_dsl::users.load::<User>(&conn).unwrap();
trace!("load users took: {:?}", users_load.elapsed());
```
where `Instant::now()` creates a new Instant that represents the current time, essentially starting a stopwatch.
`trace!` lane logs the time taken to execute the query and to load the table users from the database. It uses the `trace!` macro, which is typically used for logging at a very detailed level. The `elapsed()` duration is formatted and printed to show how long the query took to execute.
The `elapsed()` method in Rust returns a `Duration` object, which represents the amount of time that has passed since the `Instant` was created with nanoseconds (ns) as the unit of time.
This information could be useful for monitoring and optimization.
The duration could be converted to different units as 
```rust
println!("Elapsed time in milliseconds: {:?}", users_load.as_millis());
println!("Elapsed time in seconds: {:?}", users_load.as_secs());
println!("Elapsed time in microseconds: {:?}", users_load.as_micros());
```

In order to collect all **_users_** ids and also all **_orders_** ids from the **_orders_** table:
```rust
let orders_ids: Vec<i32> = orders.iter().map(|x| x.id).collect();
trace!("{:?}", orders_ids.len());
let users_ids: Vec<i32> = orders.iter().filter_map(|x| x.user_id).collect();
```
`orders.iter()` creates an iterator over the **orders** vector, producing references to each **Order** object, without consuming the collection.
It returns an iterator of type `std::slice::Iter<'_, T>`, in this case `orders` is `Vec<Order>`, so **T = Order**.

`.map(|x| x.id)` takes every **orders** record, extract value from the field `id` and collects them into a vector if integers `Vec<i32>`. If there is no `id` field (hypothetically) it will panic, because according to our struct `id` in `orders` is `pub id: i32,` not `Option<i32>`.

`.filter_map(|x| x.user_id).collect()` creates a vector (**user_ids**) that contains the **user_id** field of each **order** from the **orders** vector, but only if **user_id** is `Some(i32)`. The `filter_map` function filters out **None** values and collects only `Some(i32)` values into the vector. This results in a list of **user_id** from **orders**.

I want to get **currency**, corresponding with the **order_id** so for that I load **currencies** table, filtering it by two fields: `type` and `type_id`
```rust
let currencies: Vec<Currency> = currencies_dsl::currencies
        .filter(currencies_dsl::type.eq("Order"))
        .filter(currencies_dsl::type_id.eq(any(&orders_ids[..])))
        .load::<Currency>(&conn)
        .unwrap();
```
`.filter(currencies_dsl::type.eq("Order"))`
filters the **currencies** table to only include rows where the type column is equal to "Order".

`.filter(currencies_dsl::type_id.eq(any(&order_ids[..])))`
filters the **currencies** table to only include rows where the **type_id** column matches one of the **order_ids** collected from the **users** table.

Now I want to have a **HashMap** where keys are `order_id` and the values are references to the corresponding **Currency** objects.

```rust
let currencies_by_order_id: HashMap<i32, &Currency> = currencies
    .iter()
    .map(|x| (x.type_id.unwrap(), x))
    .collect();
```
`currencies.iter()`

Creates an iterator over the currencies vector, producing references to each **Currency** object.

`map(|x| (x.type_id.unwrap(), x))`

For each **Currency** object **x**:
`x.type_id.unwrap()` retrieves the `type_id` value from the `Option<i32>`. This assumes that all `type_id` values are `Some` and will panic if any `type_id` is **None**.
The closure returns a tuple **(type_id, x)**, where `type_id` becomes the key and **x** (a reference to the **Currency** object) becomes the value.

`collect()`

Converts the iterator of **(key, value)** pairs into a **HashMap**.

`HashMap<i32, &Currency>`

The resulting **HashMap** has:
Keys of type `i32`, representing the unwrapped `type_id` values.
Values of type **&Currency**, which are references to the **Currency** objects.

Which creates kind of a lookup table, when I can pass a key (type_id = order_id in this case) and get a corresponding **Currency** object with all the fields.

**CombinedOrder** combines fields from both tables and includes a derived field **amount_usd** using the information from currencies table and **amount_with_tax** using the information from **taxes** table.

```rust
let parquet_records: Vec<CombinedOrderRecord> = orders
    .iter()
    .filter(|order| order.user_id.is_some())
    .filter(|order| order.active)
    .map(|o| {
```
`orders.iter().filter(|order| order.user_id.is_some())` filters out orders where the `user_id` is **None**. This ensures only orders associated with a user are processed further.

The `.map(|o| { ... })` transforms each filtered `order (o)` (reference to `Order` ) into a new representation, producing a `CombinedOrderRecord`.

`let currency = currencies_by_order_id_id.get(&o.id)` retrieves the currency information for the current order from the `currencies_by_order_id_id` `HashMap` mapping described above, using the order's `id` as a key. If no entry exists, currency is **None**.
```rust
let conversion_rate = currency
    .map(|x| {
        x.conversion_rate
        .clone()
        .map(|cr| cr.to_f64().expect("bigdecimal to f64"))
        .expect("Unwrapping currency in Orders")
    })
    .unwrap_or(1.0);
```
extracts the conversion rate from the currency (if it exists). 
The logic:
The outer `.map(|x| {...})` operates on the optional **currency** object `Option<Currency>` and processes the **currency** if it is `Some`.
`x.conversion_rate` is also an `Option<BigDecimal>`.

So if a currency exists, and it has a value in `conversion_rate` field, its `conversion_rate` is cloned and converted to a **_f64_**. 
If conversion `to_f64()` fails, an `expect` statement ensures a panic with an error message.
If no currency exists (`currency.is_none()`), a default conversion rate of `1.0` is used via `.unwrap_or(1.0)`.

why do I need to use `clone()` for `conversion_rate`: it's due to Rust ownership rules:
`x.conversion_rate` is an `Option<BigDecimal>`, calling `.clone()` creates a copy of the `BigDecimal` value.

This is necessary because `BigDecimal` does not implement the `Copy` trait as **BigDecimal** is a complex type.
Without `.clone()`, calling `x.conversion_rate.map(...)` would move the value out of `x.conversion_rate`.

If `x.conversion_rate` is used later in the code, this would cause a compile-time error because the value has been moved.

In order to avoid cloning now I'd better do
```rust
let conversion_rate = currency
    .as_ref() // Borrow the inner value
    .map(|x| {
        x.conversion_rate
            .as_ref() // Borrow the inner value
            .map(|cr| cr.to_f64().expect("bigdecimal to f64"))
            .expect("Unwrapping currency in Orders")
    })
    .unwrap_or(1.0);
```
where `as_ref()` converts `Option<T> to Option<&T>`, allowing borrowing the value instead of moving or cloning it.
Probably the better choice would be simplifying the code with
```rust
let conversion_rate = currency
    .and_then(|x| x.conversion_rate)
    .map(|cr| cr.to_f64().expect("bigdecimal to f64"))
    .unwrap_or(1.0);
```
`currency.and_then(|x| x.conversion_rate.clone())` if **currency** is Some, it extracts **x.conversion_rate** (which is also an **Option**).
If currency is `None`, it returns `None`.

`.map(|cr| cr.to_f64().expect("bigdecimal to f64"))` converts the **BigDecimal** to an **f64** if **x.conversion_rate** is **Some**.

`.unwrap_or(1.0)` - a default value of 1.0 if either **currency** or **x.conversion_rate** is **None**.

`let currency_name = ...` uses the same logic:
If no **currency** exists, the fallback is `.unwrap_or_else(|| "USD".to_string())`.
The same logic is for extracting `user_email` and `country` from the **User** object.

With similar logic I extract **Tax** object based on the corresponding `order_id` and getting a `tax_rate` via 

`let tax_rate = taxes.map(|x| x.rate.to_f64().expect("tax rate bigdecimal to f64"));` with a descriptive error message - in case the conversion to `f64` failed I know which field is responsible for that.


**CombinedOrder** combines fields from both tables and includes a derived field **amount_with_tax**.
`o.amount * (1.0 + tax_rate),`

After all the fields are calculated, they are collected into the `Vec<CombinedOrderRecord>` via
`collect()`
The `.collect()` method collects all the `CombinedOrderRecord` instances into a new collection. The collection type depends on the type specified earlier in:
`let parquet_records: Vec<CombinedOrderRecord> = ...`

When I write the fields into struct, in some cases it's `order_id: o.order_id,` in some `u.country.clone()`, why not clone all the time? Because `order_id` here is `i32` which implements `Copy` trait and `country` which is `String` - doesn't.

After this collection I need to write the file into parquet format and upload to S3. 
What do we need to do for that?

1.  Define the **Path** & get **parquet_records** of type **CombinedOrderRecord**

    ```rust
    let path = "/tmp/combined_orders.parquet";
    let mut count = 0; // to count the number of row groups
    ...
    ```

2.  Get the schema

    ```rust
    let schema = parquet_records.as_slice().schema().unwrap();
    println!("{:?} schema", &schema);
    ```

    Here: 
    `as_slice()` converts the vector `parquet_records` into a slice (&[T]), allowing slice-based operations. The _**as_slice**_ method (or the **_&v[..]_** syntax) is used to create a slice from a vector. A slice is a reference to a contiguous sequence of elements in a collection. Using `as_slice` allows me to pass a vector as a slice without transferring ownership. If I need to use a subset of vector's elements, I'd use `&v[1..4]`. Also `ParquetRecordWriter` is designed to work with a slice, and if I try to do 
```rust
let schema = &parquet_records.schema().unwrap();
```
I'll get `Method schema not found in the current scope for type Vec<CombinedOrderRecord>`

    `.schema()` is a method provided by a trait **_ParquetRecordWriter_**, which extracts the Parquet schema from the data structure (`schema()` returns `Result<parquet::schema::types::TypePtr, parquet::errors::ParquetError>` ).

    `.unwrap()` is used to handle the Result type returned by `.schema()`, which will panic if the operation fails. If the schema extraction is successful, it returns the schema object.

3.  Open file for writing: 
    here I'm borrowing **path** variable, as I need to use it later for the reader.

    ```rust
    let file = std::fs::File::create(&path).unwrap();
    let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();
    ```

    `std::fs::File::create(&path):`
    Opens the specified file for writing or creates the file if it doesn't already exist and panics on failure.
    
    `SerializedFileWriter::new(file, schema, props())`:
    Initializes a Parquet file writer.
    Takes the file, schema, and writer properties (props()) as inputs.

    `props()`: Refers to writer properties. Initially we had to define them in each task as `let props = Arc::new(WriterProperties::builder().build());` but now it's getting pulled from `project_parquet` as
    
    ```rust
    pub fn props() -> Arc<WriterProperties> {
        Arc::new(
            WriterProperties::builder()
                .set_compression(parquet::basic::Compression::GZIP)
                .build(),
        )
    }
    ```
    where
    `pub fn props() -> Arc<WriterProperties>`  defines a public function named **props** that returns a reference-counted (**Arc**) instance of **WriterProperties**.
    **Arc** stands for **_Atomic Reference Counting_**, which allows safe, shared ownership of data across multiple threads in a concurrent environment.
    `WriterProperties` is a struct from the **_parquet_** crate used to configure properties for writing Parquet files.
    
    `WriterProperties::builder()` initializes a builder pattern for creating `WriterProperties` instances, which allows chaining of configuration methods.

    `.set_compression(parquet::basic::Compression::GZIP)` configures the writer to use **_GZIP_** compression for **_Parquet_** file output.

    `parquet::basic::Compression::GZIP` specifies GZIP as the compression codec.

    `.build()` finalizes and constructs an instance of `WriterProperties` with the specified settings.

    `Arc::new(...)` wraps the created `WriterProperties` inside an **_Arc_**, enabling shared ownership.
     
4.  Write data to the file
    
    ```rust
    let mut row_group = pfile.next_row_group().unwrap();
    (&parquet_records[..])
        .write_to_row_group(&mut row_group)
        .expect("can't 'write_to_row_group' ...");
    pfile.close_row_group(row_group).unwrap();
    count += 1;
    println!("{} count", count);
    ```

    `pfile.next_row_group()` 
    Prepares the next row group for writing.
    Row groups are logical blocks of rows within a Parquet file.

    `write_to_row_group`
    Serializes the `parquet_records` and writes them to the current row group.
    Panics with a custom error message if writing fails.

    `pfile.close_row_group(row_group)`
    Closes the row group after writing.

    `count`
    Tracks the number of row groups written.
    This code increments and prints it.
    
5.  Finalize the file
    `pfile.close().unwrap();`

    `.close()`- when writing data to a file, it is often buffered in memory before being written to disk.
    Calling `close()` ensures  that resources are properly released and all buffered data is written (flushed) to the file system, preventing data loss.
    
    
6. Read metadata from the file for prometheus metrics
    
    ```rust
    let reader = SerializedFileReader::try_from(path).unwrap();
    let parquet_metadata = reader.metadata();
    let file_metadata = parquet_metadata.file_metadata();
    let rows_number = file_metadata.num_rows();
    (path.into(), rows_number)
    ```

    `SerializedFileReader::try_from(path)`
    Opens the written Parquet file for reading and reads the file metadata for verification or further processing. Here, path is borrowed, this is because the method `try_from` doesn't take ownership of `path` variable, it takes a reference (`&path`), and so no ownership transfer occurs. The ownership of `path` remains with the original variable.

    `file_metadata.num_rows()`
    Retrieves the number of rows written to the file.

    `(path.into(), rows_number)`
    Returns the file `path` and the number of rows as the output of the task.
    The `into()` method consumes `path` and attempts to convert it into the type specified in the tuple (**String** for this function).

7. Running the task: after we defined the function `pub fn combined_orders()` we need to implement the trait to run the task that fetches data and stores it. 
   For that after the function we have:

```rust
pub struct CombinedOrdersTask {}

impl ProjectTask for CombinedOrdersTask {
    fn run(&self, postgres_uri: &str) -> (String, i64) {
        combined_orders(postgres_uri)
    }
}
```
`CombinedOrdersTask` is an empty public struct, used as a unit struct to represent a specific task related to processing combined orders.
It acts as a concrete implementation of the `ProjectTask` trait. Traits in Rust cannot be implemented directly for functions (`combined_orders`).
By defining `CombinedOrdersTask`, I can implement the `ProjectTask` trait and provide a run method that calls `combined_orders`. Using a trait `ProjectTask` allows us to treat different tasks uniformly (which we do in `project_cli`) and if later I need to add more functionality to tasks (e.g., logging, error handling, or retries), I can do so in the `run` method of the trait implementation without changing the functions themselves.

The `run` function is implemented to execute the `combined_orders` function, which processes data from the PostgreSQL database.
It follows the `ProjectTask` trait signature (`fn run(&self, postgres_uri: &str) -> (String, i64);`).

where `ProjectTask` (defined in prelude in `project_tasks/mod.rs`) is:

```rust
pub trait ProjectTask: Sync + Send + RefUnwindSafe + UnwindSafe {
    fn run(&self, postgres_uri: &str) -> (String, i64);
}
```
What it does:

This defines a trait `ProjectTask` that any implementing type must satisfy.
Types implementing `ProjectTask` must:
- Be thread-safe (`Sync and Send`).
- Be safe to use across unwind boundaries (`RefUnwindSafe and UnwindSafe`).
- Provide a `run` function with the specified signature, which takes a PostgreSQL connection string (`postgres_uri`) and returns a tuple `(String, i64)`.

This trait is used to define a shared interface for a family of tasks that can perform some operation and return results.

#### Streaming Tasks

Because our program started from reading small-normal size tables we started using **_Diesel_**, but then we got hit by program getting OOM or getting into the conflict with RDS instance due to loading the huge volume of data at once from the big tables.
To handle that some tasks were recreated using **_sqlx_** crate, which was used for asynchronously reading large tables from a PostgreSQL, processing the data, and writing it to a Parquet file format.

Why use **_sqlx_** instead of diesel for large tables?

**Asynchronous Database Access (Key Advantage):** 

- **_sqlx_** provides **_async_**/**_await_** support, which allows for non-blocking database operations.
This is crucial for handling large datasets, as it enables efficient streaming and processing without blocking the main thread, improving throughput and scalability.
In contrast, _**diesel**_ primarily uses synchronous operations, which can cause blocking issues when working with large datasets.

**Efficient Streaming of Large Data:**

The code uses `sqlx::query_as` and `.fetch(&pool)` to stream results.
Streaming helps in processing large tables in chunks instead of loading everything into memory at once.

**Lightweight and Compile-time Checked Queries**

**_sqlx_** offers compile-time SQL query verification with strong typing, ensuring correctness and performance optimization at build time.
_**Diesel**_ often requires complex query-building and lacks full async support.

**Flexibility with Dynamic Queries**

_**sqlx**_ allows direct string-based SQL queries (`query_as::<sqlx::Postgres, User>(&query);`), making it easier to work with dynamic queries.
**Diesel**'s ORM-like approach can be restrictive when working with dynamically changing query structures.

In the example below I'm constructing the query with extra fields via 
```rust
query.push_str(fields);
```
It's also possible to add conditions 
```rust
async fn fetch_users(pool: &PgPool, filters: HashMap<&str, &str>) -> Result<Vec<User>> {
    let mut query = "SELECT id, name, email FROM users WHERE 1=1".to_string();

    if let Some(min_date) = filters.get("min_date") {
        query.push_str(&format!(" AND date >= '{}'", min_date));
    }

    let exclude_domains = vec!["example.com", "example2.com"];
    for domain in &exclude_domains {
        query.push_str(&format!(" AND email NOT LIKE '%@{}'", domain));
    }
    let users = sqlx::query_as::<_, User>(&query)
        .fetch_all(pool)
        .await?;

    Ok(users)
}
#[tokio::main]
async fn main() -> Result<()> {
    // Database connection
    let pool = PgPool::connect("postgres://user:password@localhost/dbname").await?;

    // Example filters (simulate user input)
    let mut filters = HashMap::new();
    filters.insert("min_date", "2025-01-15");
    // Fetch users based on dynamic filters
    let users = fetch_users(&pool, filters).await?;
```
where `WHERE 1=1` allows appending conditions without worrying about the first `AND` clause.
Conditions are added based on available filters (`email, min_date`). If additional filters are added, the query adapts accordingly.
The query string is built dynamically at runtime. 

when with Diesel it would look like
```rust
use diesel::prelude::*;
use my_project::schema::users::dsl::*;

fn fetch_users(conn: &PgConnection, user_name: Option<&str>, user_email: Option<&str>) -> Vec<User> {
    let mut query = users.into_boxed(); // Allows dynamic query construction

    if let Some(name) = user_name {
        query = query.filter(name.eq(name));
    }

    if let Some(email) = user_email {
        query = query.filter(email.eq(email));
    }

    query.load::<User>(conn).expect("Error loading users")
}
```
So for each extra filter value in **Diesel** I need to write extra code, when for each extra filter value in **sqlx** I just add the filter line to the code.

**_sqlx_** allows: 
- String-Based Query Construction: I can construct queries dynamically without predefined schema definitions.
- Flexibility with Input: Supports building queries based on user-provided filters without writing multiple query versions.
- No Compile-Time Schema Enforcement(very important if I want to check what I'm getting): Unlike Diesel, sqlx allows running ad-hoc queries without defining schema structs.

For **_sqlx_**  `mod.rs` I have traits `ProjectStreamTask` and `HugeStreamTask`  which define an interface to run asynchronous tasks that interact with PostgreSQL and return results.
They enforce that implementing structs must be `Send + Sync + Debug + UnwindSafe`, ensuring thread safety and error resilience.
```rust
#[async_trait]
pub trait ProjectStreamTask: Debug + Sync + Send + RefUnwindSafe + UnwindSafe {
    async fn run(&self, postgres_uri: &str) -> (String, i64);
}

#[async_trait]
pub trait HugeStreamTask: Debug + Sync + Send + RefUnwindSafe + UnwindSafe {
    async fn run(&self, postgres_uri: &str) -> Vec<(NaiveDate, PathBuf, u128, i64)>;
}
```
In the [**streaming_task.rs**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-streaming_task-rs) the `ProductRecordStream` struct, derived with `ParquetRecordWriter` and `sqlx::FromRow`, and `Default` and `Debug` which provide automatic implementations of functionalities that help with extracting struct field names, fetching data from Postgres and writing it to Parquet files.

`sqlx::FromRow`  derive macro enables the struct to be used with SQLx to map database query results directly into Rust structs.

It allows SQLx to deserialize rows from a database query into instances of `ProductRecordStream`.

For example, using this query SQLx will automatically map the database columns to the corresponding struct fields.
```
let result = sqlx::query_as::<sqlx::Postgres, ProductRecordStream>(&query).fetch(&pool);
```
`ParquetRecordWriter`  derive macro enables automatic writing of struct instances to Parquet files.

`Default` derive macro provides a way to create a default value for a struct (or other types) when no specific values are provided.

When the `Default` trait is derived, Rust will automatically generate an implementation for it that initializes all struct fields with their respective default values.
Default values for standard types in Rust:
```rust
i64 → 0
Option<T> → None
String → "" (empty string)
Vec<T> → empty vector vec![]
bool → false
..
```

This task:
```rust
pub async fn products(pg_uri: &str) -> anyhow::Result<(String, i64)> {
```
Connecting to PostgreSQL 
```rust
let pool = PgPool::connect(pg_uri).await?;
```

Creating a Placeholder Struct Instance: This creates a vector with a default instance of `ProductRecordStream` to:
- Simulate a dataset structure.
- Use it for schema introspection to dynamically build the query.

```rust
let fake_products = vec![ProductRecordStream { 
  ..Default::default()
}];
```
Why do I need this placeholder? Because this placeholder struct instance is used to introspect the schema of `ProductRecordStream` dynamically. In Rust, struct fields aren't accessible at runtime in the same way as in dynamic languages (e.g., Python). Instead, I need to create an instance of the struct to analyze its fields and types.
The struct `ProductRecordStream` is annotated with `#[derive(ParquetRecordWriter, sqlx::FromRow)].` These derive macros enable schema extraction.
Creating a default instance (`..Default::default()`) allows access to the schema, which is used later in the code to generate a list of database columns.

Since the struct fields represent database columns, creating an instance helps dynamically determine column names required for query building.
Without this, I would need to hard-code column names (like in the 'normal' tasks described above), which reduces flexibility.

The obvious advantages:
- If the struct definition changes (e.g., new fields are added), the introspection ensures that the SQL query automatically adapts, avoiding manual updates.
- the program avoids errors as without creating an instance, trying to access field names programmatically would lead to compilation errors because Rust’s type system doesn't allow reflection like dynamically typed languages.

Extracting Schema Information from the Struct
```rust
let schema = fake_products.as_slice().schema().unwrap();
let schema_2 = fake_products.as_slice().schema().unwrap();
let schema_vec = schema_2.get_fields();
```
The code extracts schema details from the sample data.
`fake_products.as_slice().schema().unwrap()` retrieves schema metadata, such as field names and types.

`schema_vec = schema_2.get_fields();` gets a list of fields (columns) for further processing.

Why do I need both `schema` and `schema_2`? Because of Rust ownership rules we can have all different kinds of errors while trying to use some variable which we don't own anymore.

later in the function I have:
```rust
for i in schema_vec {
... .
}
let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();
let fields: &str = &fields.join(", ");

```
If I only have `schema` and then do `let schema_vec = schema.get_fields();` then I get an error 
```rust
let schema_vec = schema.get_fields();
   |             ------------------- borrow of `schema` occurs here
...
let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();
   |                                            ^^^^^^ move out of `schema` occurs here
...
let fields: &str = &fields.join(", ");
   |                ----------------- borrow later used here

```
Why?
```rust
let schema = fake_products.as_slice().schema().unwrap();
let schema_vec = schema.get_fields();
```
`schema` is a binding that holds a value (an instance of Schema).
`schema_vec` borrows from schema by calling `.get_fields()`.

`let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();`

`schema` is moved into `SerializedFileWriter::new()` after this move, schema cannot be used anymore in this function.

`let fields: &str = &fields.join(", ");` if `schema_vec` is still being used after `schema` was moved, the borrow becomes invalid because schema no longer exists.


Rust enforces ownership and borrowing rules:

- If a value is moved, it cannot be used again.
- If a value is borrowed, it cannot be moved while it is still borrowed.

In my case:

`schema_vec` borrows schema when calling `.get_fields()`.
`schema` is moved into `SerializedFileWriter::new()`, invalidating the borrow.

Could be fixed by doing 

`let mut pfile = SerializedFileWriter::new(file, schema.clone(), props()).unwrap();` so here `schema.clone()` creates a new copy, and `schema` remains valid.
I can Not do `SerializedFileWriter::new(file, &schema, props())` because `SerializedFileWriter` expects `Arc<Type>` not `&Arc<Type>`.

If I do `let schema_vec = &schema.get_fields();` then I get 
```rust
36 |     for i in schema_vec {
   |              ^^^^^^^^^^ `&&[std::sync::Arc<dracula_parquet::prelude::parquet::schema::types::Type>]` is not an iterator
   |
   = help: the trait `std::iter::Iterator` is not implemented for `&&[std::sync::Arc<dracula_parquet::prelude::parquet::schema::types::Type>]`
   = note: required for `&&[std::sync::Arc<dracula_parquet::prelude::parquet::schema::types::Type>]` to implement `std::iter::IntoIterator`

```

If I try to clone my vector `let schema = fake_products.clone().as_slice().schema().unwrap();` I'd get an error about trait `Copy` not being satisfied and if I add `#[derive(Clone)]` to my struct I'd get the same error about `borrow of `schema``.

If I do `let schema_vec = schema.clone().get_fields();` I'd get 
```rust
let schema_vec = schema.clone().get_fields();
                 ^^^^^^^^^^^^^^             - temporary value is freed at the end of this statement
                 |
                 creates a temporary value which is freed while still in use
...
for i in schema_vec {
         ---------- borrow later used here
```
which means:
`schema.clone()` creates a temporary clone of schema.
Then, `.get_fields()` is called on that temporary clone.
However, because `clone()` returns a temporary value, it gets dropped at the end of the statement.

`schema_vec` now holds a reference to a value that no longer exists, leading to a use-after-free error when I'm trying to use it later in:
`for i in schema_vec { // Borrowing freed value`

Building field names for SQL Query:
```rust
let mut fields: Vec<&str> = vec![];
for i in schema_vec {
    if i.name() == "uuid" {
        fields.push("uuid::varchar") // because parquet wasn't supporting uuid type writing
    } else if .. {
        ... 
    } else {
        fields.push(i.name())
    }
}
println!("{:?} fields!", fields);
```
This loop iterates over all schema fields and dynamically constructs SQL-friendly field names:
- If the field is named `uuid`, it converts it to `uuid::varchar` to ensure proper type handling in SQL queries.
- Other fields are pushed as-is.
The final field list is printed for debugging purposes.

Setting up parquet file writing
```rust
let products_load = Instant::now();
let path = "/tmp/products.parquet";

let file = std::fs::File::create(&path).unwrap();
let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();
```
`Instant::now()` tracks how long the operation takes.
A Parquet file path is defined as `"/tmp/products.parquet"`.
The file is created using `std::fs::File::create(path)`.
A Parquet writer (`SerializedFileWriter`) is initialized with the schema and file properties.

Constructing the SQL Query
```rust
let table: &str = "products";

let mut query = "SELECT ".to_owned();
let fields: &str = &fields.join(", ");
query.push_str(fields);
query.push_str(" FROM ");
query.push_str(table);
```
A `SELECT` query is dynamically built by concatenating the extracted field names and appending the table name (`products`).

Query Execution with SQLX (`query_as`): Executes the SQL query asynchronously and streams results.

```rust
let result = sqlx::query_as::<sqlx::Postgres, ProductRecordStream>(&query);
let product_stream = result.fetch(&pool);
```


Processing Data in Chunks (5000 rows at a time): Streams rows from the database and writes them to a Parquet file in chunks.
```rust
let mut chunk_stream = products_stream.map(|fs| fs.unwrap()).chunks(5000);
while let Some(chunks) = chunk_stream.next().await {
    let mut row_group = pfile.next_row_group().unwrap();
    (&chunks[..])
        .write_to_row_group(&mut row_group)
        .expect("can't write_to_row_group");
    pfile.close_row_group(row_group).unwrap();
}
```
Trait Implementation (`ProductStreamingTask`): implements the trait to run the task that fetches data and stores it.
```rust
use async_trait::async_trait;
#[derive(Debug)]
pub struct ProductStreamTask {}
#[async_trait]
impl ProjectStreamTask for ProductStreamTask {
    async fn run(&self, postgres_uri: &str) -> (String, i64) {
        products(postgres_uri).await.unwrap()
    }
}
```

[//]: # (<details>)

[//]: # (	<summary>Click to expand</summary>)

[//]: # (	<pre>)

[//]: # (	Long content here)

[//]: # (	</pre>)

[//]: # (</details>)


Similar to `ProjectTask`, this defines a trait for asynchronous tasks.
The `#[async_trait]` attribute allows the run function to be an `async fn`, enabling asynchronous operations within the trait implementation.
It's  designed for streaming tasks that may involve asynchronous operations, such as reading data from a database, processing it, and returning results.
Types implementing this trait must also be thread-safe and debug-friendly.

#### Thread Safety in Rust

**Sync and Send Traits**

_**Send**_: A type that implements **Send** can be safely transferred between threads. Most primitives in Rust (like **integers** and **String**) are **Send** by default, but types with raw pointers or non-thread-safe resources (like **Rc\<T\>**) are not.

**Raw Pointers**: Rust's raw pointers (*const T and *mut T) don't have safety guarantees like borrow checking, so they require unsafe code. They are used in low-level tasks like interfacing with C code or optimizing performance.

Non-thread-safe Resources and what to use instead:

**Rc\<T\>** is not thread-safe, use **Arc\<T\>** for thread-safe reference counting.
**RefCell\<T\>** is not thread-safe, use **Mutex\<T\>** or **RwLock\<T\>** for synchronized interior mutability.

**_Sync_**: A type that implements **Sync** can be safely shared by reference (**&T**) across multiple threads. It guarantees no race conditions or undefined behavior during concurrent access.

Thread-Safe Alternatives:

Use **Arc\<T\>** instead of **Rc\<T\>** for shared ownership in multi-threaded contexts.
Use **Mutex\<T\>** or **RwLock\<T\>** instead of **RefCell\<T\>** for thread-safe interior mutability.

Sync and Send in Practice:

A type that implements both Sync and Send can be safely shared and moved between threads.
Example: **Arc\<T\>** is both **Sync** (can be shared by reference) and **Send** (can be transferred between threads).

```rust
use std::sync::Arc;
use std::thread;

let data = Arc::new(vec![1, 2, 3]);
let data_clone = Arc::clone(&data);

thread::spawn(move || {
    println!("{:?}", data_clone); // Safe because `Arc` is both `Sync` and `Send`
}).join().unwrap();
```
Not-safe example:
```rust
use std::sync::Arc;
use std::thread;

fn main() {
    let data = Arc::new(vec![1, 2, 3]);

    for _ in 0..3 {
        let data_clone = Arc::clone(&data);
        thread::spawn(move || {
            // Unsafe mutation of `Arc<Vec<T>>`
            let mut data_mut = Arc::get_mut(&mut Arc::clone(&data_clone)).unwrap();
            data_mut.push(4); // Data race. Multiple threads modifying the same Vec<T>
        });
    }
}
```
why it's not safe:
**Arc\<T\>** provides shared ownership, but it does not allow mutation safely.
**Arc::get_mut()** only works when there is a single reference. When multiple threads hold a reference, it panics.
If **data.push(4)** were possible, it could corrupt memory due to simultaneous modifications.
To avoid this we need to use `let data = Arc::new(Mutex::new(vec![1, 2, 3]));`

#### RefUnwindSafe and UnwindSafe in Rust

What Are Unwind Boundaries?

In Rust, an unwind occurs when a panic happens and the program starts cleaning up by dropping variables and freeing resources.
Code that interacts with panics must ensure that resources are safely released and that the program can recover or terminate gracefully.

**UnwindSafe Trait**

A type that implements UnwindSafe ensures that it remains in a valid state if a panic occurs while the type is being accessed or used.
For example, a struct that only contains primitive types or safe abstractions like String will be UnwindSafe.

**RefUnwindSafe Trait**

A type that implements RefUnwindSafe guarantees that it can be safely accessed through a reference (&T) across an unwind boundary.
This is a stricter guarantee than UnwindSafe because it deals with shared references.

Practical Use of Unwind Safety

These traits are mainly used in scenarios where panics can happen but the program intends to recover gracefully, such as in:
`std::panic::catch_unwind:` A function that allows catching panics and continuing execution.

```rust
  use std::panic;
    
  let result = panic::catch_unwind(|| {
    println!("Before panic");
    panic!("Oops!");
  });
  match result {
    Ok(_) => println!("Code ran successfully"),
    Err(_) => println!("Caught a panic"),
  }
```

**Summary**

**Thread-Safety (Sync and Send)**:

Ensures a type can be safely transferred (Send) or shared (Sync) between threads without causing race conditions or undefined behavior.
Important for concurrent or parallel processing.

**Unwind Safety (RefUnwindSafe and UnwindSafe)**:

Ensures a type can be safely accessed or manipulated across panic boundaries.
Important for error handling and maintaining program integrity during panics.
By combining these guarantees, Rust ensures memory safety, thread safety, and robustness in concurrent and error-prone code.


#### Parquet Writer

In order to be able to write files into parquet I'm using the crates `parquet` and `parquet_derive` as well as extra methods from `project_parquet` defined by us:

in `project_parquet`
```rust
use parquet::file::properties::WriterProperties;
use std::sync::Arc;
use parquet::file::writer::{ParquetWriter, SerializedFileWriter}; 

pub fn props() -> Arc<WriterProperties> {
    Arc::new(
        WriterProperties::builder()
            .set_compression(parquet::basic::Compression::GZIP)
            .build(),
    )
}

pub trait FileWriterRows {
    fn total_num_rows(&mut self) -> &i64;
}

impl<W: 'static + ParquetWriter> FileWriterRows for SerializedFileWriter<W> {
    fn total_num_rows(&mut self) -> &i64 {
        &50
        // &self.total_num_rows
    }
}

pub mod prelude {

    pub use super::props;
    pub use super::FileWriterRows;
    pub use parquet::file::properties::WriterProperties;
    pub use parquet::file::writer::{FileWriter, SerializedFileWriter};
    pub use parquet::record::RecordWriter;

}
```
Where:

`WriterProperties` – Provides configuration settings for Parquet file writing (e.g., compression).

`Arc` – A thread-safe reference-counting pointer to allow shared ownership across threads.

`ParquetWriter` & `SerializedFileWriter` – Handle the writing of data to Parquet files.
The difference between them is that the first defines the interface for writing Parquet(not used directly) and the second implements the interface and writes the file (used directly to write the files).

Function `fn props()`:
```rust
pub fn props() -> Arc<WriterProperties> {
   Arc::new(
     WriterProperties::builder()
     .set_compression(parquet::basic::Compression::GZIP)
     .build(),
   )
}
```
Creates and returns Parquet writer properties wrapped in an `Arc`, which allows safe sharing across multiple threads.
`set_compression(parquet::basic::Compression::GZIP)` – Sets the compression type to GZIP for efficient storage.


Trait: `FileWriterRows`
```rust
pub trait FileWriterRows {
   fn total_num_rows(&mut self) -> &i64;
}
```
Defines a trait with a method `total_num_rows` that should return a reference to an `i64` (indicating the number of rows written).

Trait Implementation for `SerializedFileWriter`

```rust
impl<W: 'static + ParquetWriter> FileWriterRows for SerializedFileWriter<W> {
   fn total_num_rows(&mut self) -> &i64 {
    // &50
    &self.total_num_rows
   }
}
```
Implements the `FileWriterRows` trait for `SerializedFileWriter<W>`, which is responsible for writing Parquet data to a file.

`W` is a generic type parameter, meaning this implementation works for any type that satisfies the given constraints.

`'static (Lifetime Bound)`  means that the type `W` must not contain any non-static references, so type `W` must live for the entire program's duration or be completely owned (no borrowed references).
The `'static` bound ensures that `SerializedFileWriter<W>` does not hold references that might expire while it's being used. This is useful when dealing with long-lived or async operations.

The issue: we used to have `&self.total_num_rows` from  `parquet::file::writer::SerializedFileWriter`
```rust
pub struct SerializedFileWriter<W: ParquetWriter> {
    buf: W,
    schema: TypePtr,
    descr: SchemaDescPtr,
    props: WriterPropertiesPtr,
    total_num_rows: i64,...
```
but after another crate update it became a private field, and we lost access to it. TODO was to figure it out but at the end we just hardcoded a meaningless number.

Module prelude
```rust
pub mod prelude {
   pub use super::props;
   pub use super::FileWriterRows;
   pub use parquet::file::properties::WriterProperties;
   pub use parquet::file::writer::{FileWriter, SerializedFileWriter};
   pub use parquet::record::RecordWriter;
   }
```
Provides a convenient way to import commonly used items by simply writing use `project_parquet::prelude::*;`.

We used to define `pub fn parquet_writer<R: RecordWriter<R>>...` in our `project_parquet` but after switching to the newer version of `parquet` there was no need in it.

After the file was written to parquet format, we needed to upload it to S3 bucket.

## AWS

The logic was described in **_project_aws_** module, which  contains functions that define the AWS SDK provider for connecting to AWS services. It handles tasks such as loading and streaming data to S3, starting AWS Glue jobs, and managing the flow of data through these services.
When we needed to perform calculations separately, such as using a machine learning model, the module was also responsible for reading data from S3, processing it, and then storing the results back into the Postgres database. This was accomplished by leveraging different versions of the AWS Rust SDK, which evolved over time as better crates became available, allowing us to take advantage of more efficient and feature-rich solutions.
The overall approach ensured smooth integration with AWS services, allowing us to handle large datasets and computational tasks in a highly scalable and cost-effective manner.

Initially we used crates for AWS:

- rusoto_core
- rusoto_s3
- rusoto_glue


But later switched to these when they become available:

- aws-sdk-s3
- aws-sdk-glue
- aws-sdk-athena
- aws-config
- aws-credential-types
- aws-smithy-async
- aws-smithy-types
- aws-smithy-runtime-api


#### Uploading to S3

Here is the [**upload**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-upload_to_s3-rs) function

What happens here:
```rust
pub async fn upload(
    path: PathBuf,
    bucket_name: &str,
    key: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    ...
}
```
`async fn`: The function is asynchronous, meaning it will return a future and can be awaited by the caller.

`path: PathBuf`: Takes a `PathBuf`, which is an owned, heap-allocated version of a file path.

`bucket_name: &str`: A reference to the name of the S3 bucket where the file will be uploaded.

`key: &str`: A reference to the key (object name) under which the file will be stored in S3.

`Return Type: Result<(), Box<dyn std::error::Error>>`

If successful, it returns `Ok(())`.
If an error occurs, it returns a boxed error (dynamic error trait).

`Box<dyn std::error::Error>`  The error type (`E`) is a boxed trait object that implements `std::error::Error`. This means:

The function can return any kind of error that implements the `Error` trait.
The error is heap-allocated using `Box`, allowing for dynamic dispatch (useful for returning different error types).
It enables propagating multiple types of errors without needing to define a specific error enum.

These operations can take time, so rather than blocking the execution of the entire program while waiting for them to complete, I allow the program to continue doing other things while waiting for the results.
Later using these functions I got into some 'freeze' but I'll write about it later.

Importing required S3 types inside the function:

```rust
use aws_sdk_s3::primitives::ByteStream;
```
This imports the `ByteStream` struct, which is used to create an S3-compatible stream from the file.
Reading the file and preparing the request body:

```rust
let body = ByteStream::from_path(Path::new(&path)).await;
```
`ByteStream::from_path(Path::new(&path))` asynchronously reads the file from the given path and creates a byte stream compatible with AWS SDK S3.

`.await` waits for the operation to complete and assigns the resulting byte stream to body.

Loading AWS S3 configuration:

```rust
let config = aws_config::from_env().region(REGION).load().await;
```
`aws_config::from_env()`: Loads AWS credentials and configuration (such as access keys, secrets) from environment variables.

`.region(REGION)`: Specifies the AWS region to use.

`.load().await`: Asynchronously loads the configuration.

Creating an S3 client:

```rust
let client = S3Client::new(&config);
```
`S3Client::new(&config)`: Creates a new AWS S3 client using the loaded configuration.

Uploading the file to S3:

```rust
let _ = client
    .put_object()
    .bucket(bucket_name)
    .key(key)
    .body(body.unwrap())
    .send()
    .await;
```
`client.put_object()`: Creates a new S3 upload request.

`.bucket(bucket_name)`: Specifies the S3 bucket.

`.key(key)`: Specifies the key (filename) under which the object is stored.

`.body(body.unwrap())`: Provides the file content as the body (using `unwrap()` to handle potential errors).

`.send().await`: Sends the upload request asynchronously.

Logging the uploaded file:
```rust
info!("Uploaded file: {}", key);
```
Logs the success message using the info! macro.

Returning success: `Ok(())`


We also used to have

```rust
let credentials_provider = DefaultCredentialsProvider::new().map_err(Box::new)?
```

but later switched to `aws_config`

#### Crawler

After uploading file to S3 we had to [**crawl**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-create_crawler-rs) it with the Glue crawler, but initially had to create the function which would create crawler if it didn't exist.

What does this function do? 
- Loads AWS credentials and region configuration.
- Checks if an AWS Glue crawler with the given name exists.
- If the crawler exists, it logs a message.
- If the crawler does not exist, it creates a new crawler targeting an S3 path.
- Logs success or failure.

Function Signature:
```rust
pub async fn create_crawler(
  crawler_name: String,
  path: String,
  _greedy: bool,
) -> Result<(), Box<dyn std::error::Error>>
```
`crawler_name: String` – The name of the crawler to be created.

`path: String` – The S3 path where the data is stored.

`_greedy: bool` – A boolean parameter (unused in the function now, but it may indicate whether to run the crawler aggressively).

When `greedy: true` in the crawler configuration, it attempts to discover and catalog as much data as possible within a single run.

`Return Type: Result<(), Box<dyn std::error::Error>>`
  - If successful, it returns `Ok(())`.
  - If an error occurs, it returns a boxed error.

3. Preparing AWS Glue Client:
```rust
let _crawler_targets = path.clone();
let iam_role = "arn:aws:iam::id:role/service-role/AWSGlueServiceRole-role".to_string();
let config = aws_config::from_env().region(REGION).load().await;
```
    `IAM Role`: The function sets up an IAM role ARN for AWS Glue to access data sources.
    
    `AWS Configuration:` It loads the AWS configuration (such as credentials, region) from environment variables asynchronously.
    
    Path Cloning: The `path.clone()` is used to avoid modifying the original string.

3. Creating AWS Glue Client:
```rust
use aws_sdk_glue::Client;
let glue = Client::new(&config);
```
AWS SDK Glue Client: The function initializes the AWS Glue client using the loaded configuration.

4. Checking if crawler exists:
```rust
    let get_crawler = glue
        .get_crawler()
        .name(crawler_name.clone())
        .send()
        .await
        .unwrap();
```
It calls AWS Glue to check if a crawler with the given crawler_name already exists.
The `.unwrap()` will panic if the request fails. As an improvement I think it's better for error handling to replace it with `?`.

6. Determining if crawler should be created:
```rust
    let must_create = match get_crawler {
        GetCrawlerOutput {
            crawler: Some(Crawler { name, .. }),
            ..
       } => match name {
            Some(_crawler_name) => false,
            _ => panic!("nothing here"),
       },
            _ => true,
       };
```
This pattern-matching block checks the AWS response:
- If the crawler exists (`Some(Crawler { name, .. })`), it returns false, meaning creation is not needed.
- If the crawler does not exist (`_` case), it sets `must_create` to true, meaning a new crawler should be created.
- If the name field is not found, it panics with `"nothing here"`, which is not a proper error handling but was working for years.
It should be changed to 
```rust
    None => {
        eprintln!("Error: Crawler name not found in the response."); 
        return Err("Crawler name missing".into());
    }
```
or change the logic to using some default values like
```rust
    let must_create = match name {
        Some(_crawler_name) => false, 
        None => {
            println!("Using default behavior since crawler name is missing.");
            true
        }
    };
```
6. Creating the Crawler If Needed:
```rust
    if must_create {
        let create_crawler = glue
           .create_crawler()
           .name(crawler_name.clone())
           .database_name("database_name".to_string())
           .role(iam_role)
           .targets(
               CrawlerTargets::builder()
                   .s3_targets(S3Target::builder().path(path).build())
                   .build(),
            )
           .send()
           .await;
           info!("create crawler success {:?}", create_crawler.unwrap())
    } else {
            info!("crawler already exists")
    }
```

It builds an AWS Glue crawler with:
`.name(crawler_name)`: The provided crawler name.

`.database_name("database_name".to_string())`: The target AWS Glue database.

`.role(iam_role)`: The IAM role ARN for Glue to assume.

`.targets(...)`: Specifies S3 as the data source (provided path).

Sends the create request and logs the success.
Uses `.unwrap()` on the response, which may panic if there's an error.

If Crawler exists: if the program logs that the crawler already exists.

The function returns successfully if all operations complete without error.

Then we need to start a crawler which was the tricky part: if the crawler has already started, it will produce an error and stop the program execution.
For that we added a part for [**waiting**](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-start_crawler-rs) with up to 20 attempts until the crawler was ready,

What it does:

- Starts an AWS Glue crawler by name.
- Implements retries in case of a running crawler.
- Handles various AWS Glue service errors (e.g., already running, not found, timeout).
- Optionally waits for the crawler to finish before exiting.
- Uses `std::thread::sleep(DELAY_TIME)` for retries.

```rust
pub async fn start_crawler(
    crawler_name: String,
    poll_to_completion: bool,
) -> Result<(), Box<dyn std::error::Error>>
```
`crawler_name: String` – The name of the crawler to start.

`poll_to_completion: bool` – A flag to determine if the function should wait for the crawler to complete its job or exit immediately.

Return Type:

`Result<(), Box<dyn std::error::Error>>` – Returns `Ok(())` if successful, or an error if something goes wrong.

Load AWS Configuration:

```rust
let config = aws_config::from_env().region(REGION).load().await;
let glue = aws_sdk_glue::Client::new(&config);
```
Loads AWS configuration settings using `aws_config::from_env()`.
Creates an AWS Glue client using the loaded configuration.

Retry Loop (Handling Failures):
```rust
let mut attempts = 0;
loop {
    let start_crawler = glue.start_crawler().name(crawler_name.clone()).send().await;
    attempts += 1;
```

The function attempts to start the crawler in a loop and keeps track of how many attempts have been made using attempts, handling the responses in the different ways:

```rust
match start_crawler {
    Ok(_) => {
        println!("crawling away on {}", crawler_name);
        break;
}
```
If the crawler starts successfully `(Ok(_))`, it prints a message and exits the loop.

If there is an error:
```rust
Err(crawler_error) => {
    if let SdkError::ServiceError(err) = crawler_error {
        match err.err() {
```
If an error occurs, the function checks if it's an AWS service error (`SdkError::ServiceError`).

The function handles specific AWS Glue crawler errors:
`CrawlerRunningException` (crawler already running):
```rust
StartCrawlerError::CrawlerRunningException(_) => {
    info!("crawler update failed due to running state. bailing out.");
    if !poll_to_completion {
        info!("crawler failed. bailing out.");
        break;
    } else {
        if attempts < 20 {
            info!("crawler already running, retrying in 5 seconds")
        } else {
            panic!("crawler has tried 20 times. dying")
        }
    std::thread::sleep(DELAY_TIME);
    }
}
```
If `poll_to_completion` is false, it exits immediately.

If `poll_to_completion` is true, it retries up to 20 times with a delay.

`EntityNotFoundException` (crawler doesn't exist):

```rust
StartCrawlerError::EntityNotFoundException(_) => {
    println!("not found")
}
```

`OperationTimeoutException` (timeout error):

```rust
StartCrawlerError::OperationTimeoutException(_) => {
    println!("timed out")
}
```

`Unhandled` error types:

```rust
StartCrawlerError::Unhandled(_) => {
    panic!("unhandled StartCrawlerErrorKind")
}
```

Unknown (everything else)errors:

```rust
_ => {
    println!("no idea")
}
```

Polling Until Completion:

```rust
if poll_to_completion {
    wait_for_crawler(&glue, &crawler_name).await?
}
```

If `poll_to_completion` is true, it calls `wait_for_crawler()` to continuously check the crawler's status until it completes.

Function Completion: `Ok(())`
Once the crawler starts (or fails gracefully), the function returns Ok(()).
Looking backwards I think it would be better to replace `std::thread::sleep` with `tokio::time::sleep(DELAY_TIME).await`, because the function is `async`, using `std::thread::sleep` may block the async runtime.
It would happen as when I call `std::thread::sleep`, it blocks the entire OS thread, meaning that:

- The runtime cannot schedule other tasks on that thread while it's sleeping.
- This can cause a significant slowdown, especially if the number of available worker threads is limited.
- Other async tasks waiting to run may be delayed unnecessarily.

But if I use `tokio` then it as other async runtimes, uses a thread pool to run tasks concurrently.

## Executing the program

Now we came to the point -how to call the tasks, aws functions etc?
For that we have directory `procject_cli` with `lib.rs` and `main.rs` files, which are structured to define and run data processing tasks related to handling Postgres data, processing it, and uploading the results to AWS S3:

`procject_cli/src/lib.rs`
This file acts as the library module, providing reusable components and configurations for my application.

```rust
extern crate openssl;
extern crate diesel;
```
These external crates provide SSL and database functionality.

Argument Parsing (Args Struct):

```rust
pub struct Args {
    pub arg_POSTGRES_URI: String,
    pub flag_table: String,
    pub flag_limit: usize,
    pub flag_upload: String,
    pub flag_file: String,
    pub flag_extra: String,
}
```
This struct is used to capture command-line arguments for database URI, table name, file upload settings, and limits.

```rust
pub const USAGE: &str = "
project

Usage:
  project (<POSTGRES-URI>) [--table=<table>] [--upload=<S3_URL>] [--file=<file>] [--extra=<file>]

Options:
  -l --limit=<LIMIT>    Number of documents per request [default: 1000]
  -h --help             Show this screen.
  -t --table=<TABLE>    Postgres table to process
  -u --upload=<S3_URL>  Target file [default: s3://bucket]
  -n --no-upload        Skip uploading to S3
  -b --file=<file>      Shows to use factors
  -k --extra=<file>     Shows to run extra data load
";
```
Provides a help message when running the command-line interface (CLI).

Task Management:
```rust
fn tasks_list() -> Vec<(&'static str, Box<dyn ProjectTask>)> {
    let tasks: Vec<(&str, Box<dyn ProjectTask>)> = vec![
        ("combined_orders", Box::new(project_tasks::tasks::CombinedOrderTask {})),
        ....
    ];
    tasks
}
```
This function returns a list of tasks that will be executed, each encapsulated in a dynamic trait object (`Box<dyn ProjectTask>`).
Here: 
`dyn ProjectTask` (Trait Object) represents any type that implements the `ProjectTask` trait (it's why we were implementing it in each task).
Since traits don't have a fixed size, they cannot be stored directly in a `Vec` (which requires fixed-size elements).

`Box<dyn ProjectTask>` (Heap Allocation)
`Box<T>` allocates `T`on the heap and stores a pointer to it.

`Box<dyn ProjectTask>` allows different struct types (implementing `ProjectTask`) to be stored in the same `Vec`, avoiding the issue of unknown size.


`project_cli/bin/main.rs`
The `main.rs` file serves as the entry point for the application and handles the execution of tasks.
- Command-line arguments are passed to specify Postgres details and file upload options.
- The application reads data from Postgres, processes it in parallel using Rayon.
- Results are written to Parquet files locally and uploaded to S3.
- AWS Glue crawlers are triggered to catalog the data.
- Errors and events are logged via Sentry and `pretty_env_logger`.

`all()` Function:
This function runs all tasks and uploads the results to S3.

Argument Parsing:
```rust
let args: Args = Docopt::new(USAGE)
    .and_then(|d| d.deserialize())
    .unwrap_or_else(|e| e.exit());
```
The command-line arguments are parsed using the Docopt library.

Task Execution Loop:

```rust
for (name, task) in tasks {
    println!("{:?} task ", name);
    let result = panic::catch_unwind(|| {
        let project_result = task.run(
            utf8_percent_encode(args.arg_POSTGRES_URI.as_str(), DEFAULT_ENCODE_SET)
            .to_string()
            .as_str(),
            );
    });
}
```
and here we see the use of implementation of `ProjectTask`
```rust
fn run(&self, postgres_uri: &str) -> (String, i64) {
    orders(postgres_uri)
}
```
Each task is run inside a `panic::catch_unwind()` to prevent crashes from propagating.


S3 Upload Handling:
```rust
tokio::task::spawn(async move {
    upload(project_file.into(), BASE_PATH, path.as_str())
    .await
    .expect("upload file to s3 from all - must work");
});
```
Files are uploaded asynchronously to AWS S3.
Here:
`tokio::task::spawn` is used to spawn a new asynchronous task on the Tokio runtime, the task runs concurrently with other tasks, allowing non-blocking execution of asynchronous code.
Returns: a `JoinHandle` that can be used to await the result of the task or cancel it.

`async move { ... }` defines an asynchronous block that will be executed by the spawned task. The `move` is used to transfer ownership of variables from the outer scope into the async block. This is necessary because the task might outlive the scope in which it was created.
It captures variables: `project_file`, `BASE_PATH`, and `path` which are moved into the async block.

`.await` is used to asynchronously wait for the upload function to complete. It yields control back to the Tokio runtime, allowing other tasks to run while waiting for the result.
If the upload function succeeds, it returns a result. If it fails, it returns an error.

Error Handling:
If a task fails, it's logged and reported to Sentry:
```rust
if result.is_err() {
    let message = format!("project GOT Panic! in {} file", name);
    sentry::capture_message(message.as_str(), sentry::Level::Warning);
}
```

`#[tokio::main]
async fn main()`
The entry point of the program, where the execution begins.

Initializes `OpenSSL` for static builds and sets up logging:

```rust
openssl_probe::init_ssl_cert_env_vars();
pretty_env_logger::init();
```

Initialize Sentry for error tracking:
```rust
let _guard = sentry::init((
    "https://..@..ingest.sentry.io/..?timeout=10,verify_ssl=0",
    sentry::ClientOptions {
    release: sentry::release_name!(),
    environment: Some("production".into()),
        ..Default::default()
    },
));
```
Thread Pool Setup:
```rust
::rayon::ThreadPoolBuilder::new()
    .num_threads(2)
    .build_global()
    .unwrap();
```
Uses the Rayon library to enable parallel processing of tasks.
We are changing number of threads, so we use `build_global`

as docs say
```rust
Calling build_global is not recommended, except in two scenarios:
- You wish to change the default configuration.
- You are running a benchmark, in which case initializing may yield slightly more consistent results, since the worker threads will already be ready to go even in the first iteration. But this cost is minimal.
```

Conditionally Running Tasks Based on `flag_table`:

If the flag is "all", it runs all tasks and uploads data.
If it's "stream_tasks", a different set of tasks is run.
```rust
if args.flag_table == "all" {
    let (_size, count) = all(args.flag_table);
    
    create_crawler(CRAWLER_NAME.to_string(), s3_path, true)
        .await
        .expect("create crawler");
    start_crawler(CRAWLER_NAME.to_string(), true)
        .await
        .expect("start crawler");

} else if args.flag_table == "stream_tasks" {
    let (_size, count) = stream_tasks().await;
    
    create_crawler(CRAWLER_NAME.to_string(), s3_path, true)
        .await
        .expect("create crawler");
    start_crawler(CRAWLER_NAME.to_string(), true)
        .await
        .expect("start crawler");
}
```
We preferred **tokio** runtime due to its more powerful and multi-threaded nature, which makes it a better fit for high-performance applications. Tokio is great in handling concurrent tasks, in scenarios such as working with databases, performing calculations, and dealing with I/O operations like reading and writing to files and cloud storage (S3).
In contrast, **async-std** is simpler and more suited to lightweight applications and CLI tools.

| Feature                          | **Tokio**                                                                                                                   | **async-std**                                                                                                                                                       |
|----------------------------------|-----------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Runtime Model**                | Uses a **multi-threaded** runtime (by default), optimized for high performance.                                             | Uses a **thread-per-task** model, hich spawns a new OS thread per async task, leading to higher overhead and less efficient CPU utilization in large applications.. |
| **Task scheduling**              | Has a cooperative task scheduler, meaning tasks voluntarily yield control, preventing any single task from starving others. | Relies on a less sophisticated scheduling model, which can lead to uneven workload distribution.                                                                    |
| **Incoming Connection Handling** | Uses a `loop` to continuously accept connections and spawn new tasks.                                                       | Uses `while let Some(stream) = listener.incoming().next().await` to iterate over connections.                                                                       |
| **Buffer Allocation**            | Uses a **fixed-size buffer** (`[0; 1024]`) for reading from the socket.                                                     | Uses a **dynamically allocated vector** (`vec![0; 1024]`), which may introduce heap allocations.                                                                    |
| **Efficiency**                   | More efficient for **high-performance, concurrent workloads** (e.g., microservices, large-scale web apps).                  | Simpler API, but less optimized for high-load scenarios. Better for **small async utilities or CLI apps**.                                                          |


These examples show implementation of a simple asynchronous HTTP server using tokio and async-std. The examples will handle incoming requests and respond with a simple message (the code is very similar)

**Tokio**
```rust
use tokio::net::TcpListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::main]
async fn main() {
let listener = TcpListener::bind("127.0.0.1:8080").await.unwrap();
println!("Listening on port 8080...");

    loop {
        let (mut socket, _) = listener.accept().await.unwrap();
        tokio::spawn(async move {
            let mut buffer = [0; 1024];
            socket.read(&mut buffer).await.unwrap();
            socket.write_all(b"HTTP/1.1 200 OK\r\n\r\nHello from Tokio!").await.unwrap();
        });
    }
}
```

**Async-std**
```rust
#[async_std::main]
async fn main() {
let listener = TcpListener::bind("127.0.0.1:8080").await.unwrap();
println!("Listening on port 8080...");

    while let Some(stream) = listener.incoming().next().await {
        let mut stream = stream.unwrap();
        async_std::task::spawn(async move {
            let mut buffer = vec![0; 1024];
            stream.read(&mut buffer).await.unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\n\r\nHello from async-std!").await.unwrap();
        });
    }
}
```



## Versions

This code was written for Rust 1.69.0. I considered updating it to Rust 1.82, but the number of changes required was significant. Since the program will be deprecated soon, updating it didn’t seem worthwhile

## Summary

### Pros of This ETL Approach

_**Improved Security:**_

Direct access to Postgres was eliminated. Only the ETL program had read access, improving security.

**_Performance Isolation:_**

The heavy computations were offloaded to the Rust program, so the Postgres instance could focus on serving transactional queries.

**_Cost Efficiency:_**

Parquet files on S3 are cheap to store and efficient to query. Scaling Postgres was no longer necessary for ETL workloads.

**_Type Safety:_**

Using Rust structs ensured type safety, reducing errors in transformations.

**_Ease of Querying:_**

By integrating with AWS Glue and Athena, I could query enriched data using SQL without additional infrastructure.

And one of the most important pros: a lot of Rust learning :) 
For me personally writing Rust code is very satisfying as it requires to know what exactly I want to do, and what exactly I want to receive as the result.


### Cons of This Approach

_**Additional Infrastructure:**_

Maintaining the Rust program, S3 buckets, and Glue crawlers adds complexity.

**_Latency:_**

Data in Athena is only as fresh as the last ETL run, so it may not be suitable for real-time use cases.

**_Initial Setup:_**

Writing and testing the Rust ETL pipeline required a significant upfront effort.

**_Conclusion_**

By moving ETL workloads to a Rust-based pipeline, we were able to address security concerns, reduce operational complexity, and optimize costs. Postgres remained focused on its core transactional role, while combined data was efficiently stored and queried using modern tools like S3 and Athena.


This approach can be give some ideas for teams looking to offload heavy ETL processes without burdening their databases.