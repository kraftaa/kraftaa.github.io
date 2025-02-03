---
layout: post
title: "From Postgres to Athena: Optimizing Workflows with Rust, Parquet, and S3"
date: 2024-12-17
img: rust3.png
tags: [Rust, AWS, S3, Postgres]
---
_Work in progress_
&nbsp;

## Table of Contents
- [Problem](#problem)
- [The Solution](#the-solution)
    - [ETL](#etl)
    - [Rust Program](#rust-program)
      - [Members](#members)
      - [Schema](#schema)
      - [Tasks](#tasks)
      - [Streaming Tasks](#streaming-tasks)
      - [Parquet Writer](#parquet-writer)

[//]: # (      - [Traits]&#40;#traits&#41;)

[//]: # (      - [AWS Module]&#40;#aws-module&#41;)

[//]: # (    - [Subsection of Main Idea 2]&#40;#subsection-of-main-idea-2&#41;)

# The idea
## Problem:

This project began several years ago as a solution for providing data for company reporting in the absence of an established ETL process. The production data resided in a Postgres RDS database, but generating reports directly from 
the primary instance was not an option. Doing so would have imposed additional load on the main application and required additional roles to handle live production data.

Moreover, we needed to perform complex computations and aggregations and store the processed results for subsequent use in reporting. While Postgres was great for handling transactional workloads, we faced some challenges when tasked with heavy computations and data enrichment.
And we didn't want to store all the calculated fields in Postgres which would denormalize the tables.


## Security Concerns:

We did not want to give direct access to the Postgres RDS instance to other services or users. Instead, we wanted a secure and controlled way to read data, transform it, and expose only selected results. Access was restricted to calls made only via a program (API calls) for security.


## Performance Issues:

Running complex calculations directly on the Postgres instance each time the user was opening the report or filtering it was affecting query performance for the main application.


## Operational Complexity:

Incorporating derived fields and merging data from multiple tables resulted in overly complex schemas for views and queries, making them increasingly difficult to manage and maintain. Additionally, several machine learning computations needed to be performed on the production data, but running these directly on live data was not feasible.


## Cost Concerns:

Scaling the Postgres instance to handle heavy ETL (Extract, Transform, Load) processes was considered expensive at that time.


# The Solution:

## ETL:

[//]: # ({% mermaid %})
[//]: # (<div class="mermaid">)
flowchart TD;
RustProgram[Rust Program] -->|Reads| PostgresRDS[PostgreSQL RDS];
RustProgram -->|Calculates & Aggregates| S3ParquetFiles[S3 Parquet Files];
AWS_GLUE[AWS Glue Crawler]-->|Crawls & Creates Schema| S3ParquetFiles[S3 Parquet Files];
S3ParquetFiles[S3 Parquet Files] -->|Tables via Glue Schema| AWSAthena[AWS Athena];
AWSAthena -->|Used in| Reports[Reports];

    %% Adding styles for clarity
    classDef process fill:#f9f,stroke:#333,stroke-width:2px;
    class RustProgram,PostgresRDS,S3ParquetFiles,AWS_GLUE,AWSAthena,Reports process;

[//]: # (</div>)

[//]: # ({% endmermaid %})


Instead of performing everything within Postgres, we built an ETL pipeline with Rust, AWS S3, GLue and Athena.


This Rust project was originally initiated by my colleague and Rust wizard, [Xavier](https://github.com/xrl). His guidance and expertise helped me not only get started with Rust but also truly appreciate its beauty, power, and advantages. Thanks to his mentorship, I’ve come to love working with Rust and have seen firsthand how it can transform complex workflows (or make it even more complex but blazing fast :wink: ) .


Here’s how it worked:


## Rust Program:

The program fetched data from Postgres, performed transformations (including derived fields and joins across tables), and saved the output in Parquet format.

Using Rust allowed us to optimize performance and maintain type safety by representing tables as Rust structs.

Rust's type-checking served as a safeguard for ensuring the integrity of production data. If the production system encountered any invalid values or NaNs, the Rust process would immediately detect the issue and send an error notification, helping to maintain data accuracy and reliability.


The Rust program was deployed in a Kubernetes environment using a Helm chart. The chart configured a service account with the appropriate role-based access to AWS services, including S3 and Glue. Additionally, the Helm chart utilized a Kubernetes secret to securely manage the connection credentials for the RDS instance.


Parquet Files on S3:


Transformed data was stored in an S3 bucket in a columnar Parquet format. This reduced storage costs and improved query efficiency.


AWS Glue + Athena:


AWS Glue was used to crawl the Parquet files on S3 and create metadata.

Athena provided a cost-efficient way to query the data using SQL. Bear in mind that Athena doesn't create real tables or materialized views, it only creates a metadata and reads everything from the file, stored in S3.
The reports leveraged Athena tables and views as the foundation for data visualization.
The cons of such approach are that it is possible to delete underlying file without getting any warnings/restrictions about dependant views, tables etc.
Athena also doesn't provide indexing as it's just a querying tool with its own flavor PrestoDB, it's lacking some Postgres methods and doesn't allow recursive functions as well as true **_materialized views_**. It also doesn't support ***CREATE TABLE LIKE*** or ***DELETE FROM*** or ***UPDATE***, but it allows to give an access to query a table without a fear that the table would be dropped as behind a hood it's a file in s3.
AWS Glue provides a mechanism for partitioning and indexing with the limitations: 
- only partition column could be used as an index
- only integer and strings could be used as an index


### Members

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

It was designed to allow for the separation of tasks and crates in Cargo.toml. This separation enabled us to build and manage each component independently, avoiding unnecessary complexity and loading all the crates in once, each . It also provided better visibility into the performance of individual areas, making it easier to track and optimize and fix each part of the system.

### Schema
#### Struct/Table Representation in Rust are in **_project_schemas_**

In order to read the tables and perform some calculations and also to ensure type safety  I had to map each Postgres table to a corresponding Rust struct. Initially, this mapping was done manually, but later I discovered the powerful _**diesel_ext**_ crate (later [_**diesel_cli_ext**_](https://crates.io/crates/diesel_cli_ext)), which allowed me to automatically map the schema from Postgres to Rust structs. I still had to create diesel _table!_ macro definition which was automated with the help of _bash_ script:

```shell
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'orders';
```
which was giving me 
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
which together with this bash script would give diesel  [_table!_macro definition](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-table_macro-sh) definition.

[//]: # (<div class="code-container">)

[//]: # ()
[//]: # (  <script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=table_macro.sh"></script>)

[//]: # ()
[//]: # (</div>)

and the final definition would be:
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
The process of creating a struct was automated through a _**Makefile**_ command. Here's how it works:


The **_create-model_** target in the _**Makefile**_ generates the necessary Rust files for each table. It begins by creating a _diesel.toml_ file for the table, which defines how the schema is printed.

The command then adds the module for the table to various locations in the project, including _**mod.rs**_ files for organizing the project’s code structure.

Using the _**diesel**_ print-schema command, the schema for the specified table is fetched from the local Postgres database and saved to a Rust file.

The _**diesel_ext**_ crate is then used to generate the Rust struct for that table, which is placed in the appropriate module.


I created also a _**template_task**_ which was a blue-print for most tasks and used the _**sed**_ command to customize tasks files (using [_**template_task**_](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-template_task-rs) ), creating a corresponding task in the project.

This streamlined the process significantly, allowing efficient table mapping and the integration of the database schema into Rust code with minimal manual intervention.


Here’s the [Makefile](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-create_model-rs)  command that does all of this.

[//]: # (<div class="code-container">)

[//]: # ()
[//]: # (  <script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=create_model.rs"></script>)

[//]: # ()
[//]: # (</div>)

This approach saved considerable time and reduced the chance of errors with types/nullables by automating the mapping process.

Now I would rather put everything into combined bash script which would run over the predefined list of tables and create _table!_ macro definition and a corresponding struct with a task, but the existing approach worked well for years and I won't change it, as its life is coming to the end due to change in the infrastructure.
Here’s an example of some Postgres tables, corresponding structs and the task combining all of them with extra calculations:


#### For instance, assume we had several postgres tables:


**Table 1: orders**

| id | user_id | amount | created_at | uuid                                   |
|----|---------|--------|------------|----------------------------------------|
| 1  | 101     | 200.5  | 2024-01-01 | "aaaaaaaa-1111-3333-5555-oooooooooooo" |
| 2  | 102     | 450.0  | 2024-01-02 | "bbbbbbbb-2222-4444-6666-pppppppppppp" |

**Table 2: users**

| id  | name    | country | created_at | email              |
|-----|---------|---------|------------|--------------------|
| 101 | Alice   | USA     | 2023-01-01 | email1@example.com |
| 102 | Bob     | Canada  | 2023-01-02 | email2@example.com |

**Table 3: products**

| id | name     | quantity | created_at | approved | price |
|----|----------|----------|------------|----------|-------|
| 1  | product1 | 350      | 2023-01-10 | true     | 35.20 |
| 2  | product2 | 70       | 2023-01-20 | false    | 41.05 |
| 3  | product3 | 2        | 2023-01-20 | true     | 11.05 |

To combine these tables and add calculated fields, the Rust program used the following [structs](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-tables_structs-rs) which looked like this:
```rust
// orders_tl.rs for Postgres diesel schema
table! {
    orders (id) {
        id -> Int4,
        user_id -> Nullable<Int4>,
        amount -> Nullable<BigDecimal>,
        created_at -> Nullable<Timestamp>,
        uuid -> Uuid,
    }
}

// order.rs for the struct
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
[//]: # (<script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=tables_structs.rs"></script>)

The table and struct definitions were organized within the _**project_schemas**_ directory. This directory included the tables and models subdirectories, each housing the respective definitions. Additionally, a **_mod.rs_** file was used to list and manage all the tables and models for easier access and modularity.

```shell
project_schemas
├── tables
└── models
```

### Tasks

Then we had to combine all the data, add some calculations, write the result into parquet file and upload to S3 into the designated busket/folder.

First we need to bring modules and structs into the scope of our `combined_orders.rs` task.

```rust
use super::prelude::*;
use std::collections::HashMap;

use project_schemas::tables::{
    orders::dsl as orders_dsl, users::dsl as users_dsl, products::dsl as products_dsl,
    currencies::dsl as currencies_dsl, taxes::dsl as taxes,
};
```

What `use super::prelude::*;` does:

This imports all public items from the prelude module defined in the parent module (super).
The `*` wildcard includes everything that is publicly available within the `prelude` module.

This is a common Rust pattern used to create a `prelude` module that contains frequently used imports, making them available to other parts of the codebase without needing repetitive use statements.
Example:

In the prelude module, there are imports like `std::time::Instant, diesel::prelude::*, bigdecimal, rayon::prelude::*`, etc. By doing `use super::prelude::*;`,  `combined_orders.rs` file can directly use these items without specifying them individually.

The full [prelude](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-task_mod-rs) code.

[//]: # ()
[//]: # (<div class="code-container">)

[//]: # ()
[//]: # (  <script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=tasks_mod.rs"></script>)

[//]: # ()
[//]: # (</div>)

which means I can use all public items from this module.
Where
The line `pub use ::function_name::named;` refers to re-exporting the named macro or function from the external crate function_name.
My idea was to use it for generating a file name on the fly for writing it down as a parquet file (it was at the beginning of my Rust journey) however, `use` cannot be used to dynamically retrieve the name of a function at runtime.

In theory, what it does:

`function_name` Crate
The `function_name` crate provides a procedural macro to retrieve the name of the current function at runtime in Rust. It is often used for logging, debugging, or tracing purposes.

`named Macro`
The named macro is a part of the `function_name` crate. It allows to annotate a function so that I can programmatically access its name as a string.

When I apply `#[named]` to a function, it makes the name of the function accessible via a special constant or variable, usually _function_name_.
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
```
The prelude model is inside `mod.rs` file which is in

```shell
project_tasks
├── src
   └── tasks 
         ├── mod.rs
         ├── combined_orders.rs
         └── .. other tasks
        
└── Cargo.toml
```
In `mod.rs`:
```rust
mod combined_orders; 
pub use self::combined_orders::*;
```
What it does:

`pub use self::combined_orders::*;` re-exports all public items from the **_combined_orders_** module, making them available to other parts of the project that import this parent module.
This pattern is often used in a module hierarchy to provide a clean interface to submodules by selectively exposing their contents.

then in the task `combined_orders.rs`:
```rust
use std::collections::HashMap;
```
Which imports the HashMap type from the Rust standard library (**_std::collections_**) into scope.

```rust
use project_schemas::tables::{ ... };
```
This line imports specific modules from `project_schemas::tables` module, and it includes additional scoping and aliasing functionality.

What Happens Here:
`orders::dsl as orders_dsl`: Imports the dsl module from `project_schemas::tables::orders` and renames it as **_orders_dsl_**. I can now use it as `orders_dsl` throughout the file.
`dsl` stands for `domain-specific language`, which is a set of helper types, methods, or macros to construct SQL queries using the **Diesel** ORM library for working with tables and columns in our postgres database.

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
Here `#[derive(ParquetRecordWriter)]` that tells the Rust compiler to automatically implement the trait `ParquetRecordWriter` for the struct `CombinedOrderRecord`. 

The `ParquetRecordWriter` trait is a part of an external library `parquet_derive` which implements ``#[proc_macro_derive(ParquetRecordWriter)]`  which defines a procedural macro that will be triggered by the #[derive(ParquetRecordWriter)] attribute applied to a struct or enum.
It will handle the input, fields/types and write the struct to a file in Parquet's binary format.

Then there is the task itself, `pub` which means it can be called outside the module,
the task takes as input a reference to a string (`&str`), representing PostgreSQL connection URI,  and returns a tuple of **String** and **bigint**.
The full task code is [combined_orders.rs](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-combined_orders-rs)

```rust
pub fn combined_orders(pg_uri: &str) -> (String, i64) {
    let conn = PgConnection::establish(pg_uri).unwrap();
    let products_load = Instant::now();
    let products = products_dsl::products.load::<Product>(&conn).unwrap();
    trace!("load products took: {:?}", products_load.elapsed());
```
Here:

[//]: # (_Order_, _User_, _Product_, _Currency_ and  _Tax_ represent the tables fetched from Postgres.)
```shell
let products = products_dsl::products.load::<Product>(&conn).unwrap();
```
is part of a query using _Diesel_, an _ORM (Object-Relational Mapper)_ library for interacting with databases in Rust, which allows to interact with a relational database using the programming language's objects (e.g. structs) instead of writing raw SQL queries. Diesel ensures structs match database schema with implementing trait *_Queryable_* for the struct. It generates the necessary code to convert a row from a database table into an instance of the struct. The struct fields must match the columns in the database table (in name and type)
This line brings into scope the _DSLs (Domain-Specific Languages)_ for interacting with tables in the database. Diesel uses DSLs to generate SQL queries and map the results to Rust types. The _products::dsl, orders::dsl_ etc refer to the corresponding tables, and I'm giving them aliases (_orders_dsl, users_dsl_, ...) for convenience and loading, filtering using DSL methods.

**_products_dsl::products**_

_products_dsl_ is the alias created for _products::dsl_. _Diesel_ automatically generates a _products_ variable (referring to the _products_ table in the database) within this DSL module, which represents the table in the database.

``.load::<Product>()`` is a Diesel method used to execute the query and load the results into a collection of Rust structs `Vec<Product>`.

_Product_ is a _Rust_ struct representing the schema of the _products_ table (i.e., it maps the columns of the _products_ table to fields in the _Product_ struct).

_&conn_ is a reference to a database connection, which is used to execute the query against the database. This connection is established using Diesel’s connection API ( _PgConnection_ for PostgreSQL).

_.unwrap()_ is used to unwrap the _Result_ returned by ``load::<Product>()``. This method will either return the query results (if successful) or panic if there was an error.
Usually it is discouraged to use `unwrap` in production code unless I am certain that the query will succeed, as it causes the program to panic on an error.
We were using `unwrap` as wanted the program to panic and stop running, which will give us a clear sign that the data was not updated.
If I implemented it now I would rather use `expect` with the custom message but keep the panicking behaviour.
```shell
let products = products_dsl::products
    .load::<Product>(&conn)
    .expect("Failed to load products from the database");
```
Or this one to return an error and later handle the error in some way

```shell
let products = match products_dsl::products.load::<Product>(conn) {
        Ok(products) => products,
        Err(e) => {
            eprintln!("Error loading products: {}", e);
            return Err(e); // Return early with the error
        }
    };
```
Definitely NOT this one `unwrap_or_else` like this 
```shell
let products = products_dsl::products
    .load::<Product>(&conn)
    .unwrap_or_else(|e| {
        eprintln!("Error loading products: {}", e);
        Vec::new() // Return an empty vector as the fallback
    });
```
as here I will get an empty `Vec<Product>` into my data.

Usually the `panic!()` was caused by changes in the underlying Postgres tables, like removed column, unexpected type etc. I couldn't dynamically construct a struct in Rust with Diesel - so if I had a column in my _table!_ macro definition and a struct but `.load::<Product>` didn't find it - it will result in panic.
In that case running the task which was loading this table further didn't make sense hence `panic!()` behaviour was justified.

There is also an operator **_?_** which operator propagates errors if any occur during the creation of the file writer avoiding unexpected panic. 
Requires `Result/Option` return:
- If the operation returns _**Ok(value)**_, it extracts the value and continues execution.
- If the operation returns **_Err(error)_**, it propagates the error to the calling function.

Taking into account that the continuing the task without the connection to Postgres didn't make any sense, I have not considered this option.

I wanted to see how long it takes to load some tables, for that I had
```rust
    let users_load = Instant::now();
    let users = users_dsl::users.load::<User>(&conn).unwrap();
    trace!("load users took: {:?}", users_load.elapsed());
```
where _**Instant::now()**_ creates a new Instant that represents the current time, essentially starting a stopwatch.
_**trace!**_ lane logs the time taken to execute the query and to load the table users from the database. It uses the _trace!_ macro, which is typically used for logging at a very detailed level. The _**elapsed()** duration is formatted and printed to show how long the query took to execute.
The _**elapsed()**_ method in Rust returns a _**Duration**_ object, which represents the amount of time that has passed since the _Instant_ was created. The unit of time in _**Duration**_ is typically in nanoseconds (ns).
This information could be useful for monitoring and optimization.
The duration could be converted to different units as 
```rust
println!("Elapsed time in milliseconds: {:?}", users_load.as_millis());
println!("Elapsed time in seconds: {:?}", users_load.as_secs());
println!("Elapsed time in microseconds: {:?}", users_load.as_micros());
```

I want to collect all **_users_** ids and also all **_orders_** ids from the **_users_** table
```rust
let users_ids: Vec<i32> = users.iter().map(|x| x.id).collect();
trace!("{:?}", users_ids.len());
let order_ids: Vec<i32> = users.iter().filter_map(|x| x.order_id).collect();
```
`users.iter()` creates an iterator over the users vector, producing references to each _User_ object, without consuming the collection.
It returns an iterator of type `std::slice::Iter<'_, T>`, in this case `users` is `Vec<User>`, so T = User.

`.map(|x| x.id)` takes every users record, extract value from the field `id` and collects them into a vector if integers `Vec<i32>`.

`.filter_map(|x| x.order_id).collect()` creates a vector (_order_ids_) that contains the _order_id_ field of each _user_ from the _users_ vector, but only if _order_id_ is _Some(i32)_. The _filter_map_ function filters out _None_ values and collects only _Some(i32)_ values into the vector. This results in a list of _order_ids_ from users.

I want to get _currency_, corresponding with the _product_id_ so for that I load _currencies_ table, filtering it by two fields: `type` and `type_id`
```rust
let currencies: Vec<Currency> = currencies_dsl::currencies
        .filter(currencies_dsl::type.eq("Product"))
        .filter(currencies_dsl::type_id.eq(any(&products_ids[..])))
        .load::<Currency>(&conn)
        .unwrap();
```
`.filter(currencies_dsl::type.eq("Order"))`
Filters the _currencies_ table to only include rows where the type column is equal to "Order".
`.filter(currencies_dsl::type_id.eq(any(&order_ids[..])))`
Filters the _currencies_ table to only include rows where the _type_id_ column matches one of the _order_ids_ collected from the users table.

Now I want to have a _HashMap_ where keys are `order_id` and the values are references to the corresponding _Currency_ objects.

```rust
let currencies_by_order_id: HashMap<i32, &Currency> = currencies
    .iter()
    .map(|x| (x.type_id.unwrap(), x))
    .collect();
```
`currencies.iter()`

Creates an iterator over the currencies vector, producing references to each _Currency_ object.

`map(|x| (x.type_id.unwrap(), x))`

For each _Currency_ object _x_:
`x.type_id.unwrap()` retrieves the `type_id` value from the `Option<i32>`. This assumes that all `type_id` values are _Some_ and will panic if any _type_id_ is _None_.
The closure returns a tuple _(type_id, x)_, where _type_id_ becomes the key and x (a reference to the _Currency_ object) becomes the value.

`collect()`

Converts the iterator of _(key, value)_ pairs into a HashMap.

`HashMap<i32, &Currency>`

The resulting _HashMap_ has:
Keys of type _i32_, representing the unwrapped _type_id_ values.
Values of type _&Currency_, which are references to the _Currency_ objects.

Which creates kind of a lookup table, when I can pass a key (type_id = order_id in this case) and get a corresponding _Currency_ object with all the fields.

```rust
    let mut count = 0;
    let path = "/tmp/combined_orders.parquet";
    let path_meta = <&str>::clone(&path);
```
Before starting the collection of all the data I define the path/name of the future parquet file I'm going to write data into.
`let path_meta = <&str>::clone(&path);` is needed as I wanted to extract metadata of the file, and for that I needed to clone `path` value and pass it further as the reference (why can't I just use a reference - check the logic).
_CombinedOrder_ combines fields from both tables and includes a derived field _amount_usd_ using the information from currencies table and _amount_with_tax_ using the information from taxes table.

```rust
    let parquet_records: Vec<CombinedOrderRecord> = orders
        .iter()
        .filter(|order| order.user_id.is_some())
        .filter(|order| order.active)
        .map(|o| {
```
`orders.iter().filter(|order| order.user_id.is_some())` filters out orders where the _user_id_ is _None_. This ensures only orders associated with a user are processed further.

The `.map(|o| { ... })` transforms each filtered order (o) into a new representation, producing a `CombinedOrderRecord`.
`let currency = currencies_by_order_id_id.get(&o.id)` retrieves the currency information for the current order from the `currencies_by_order_id_id` `HashMap` mapping described above, using the order's id as a key. If no entry exists, currency is None.
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
`currency.map(|x| ...)` operates on the optional currency object.
If a currency exists, its `conversion_rate` is cloned and converted to a **_f64_**. 
If this fails, an `expect` statement ensures a panic with an error message.
If no currency exists (`currency.is_none()`), a default conversion rate of `1.0` is used via `.unwrap_or(1.0)`.

why to I need to use `clone()` for _conversion_rate_:
It's due to Rust ownership rules:
_x.conversion_rate_ is an _Option<BigDecimal>_, calling _.clone()_ creates a copy of the _BigDecimal_ value.

This is necessary because BigDecimal does not implement the _Copy_ trait as _BigDecimal_ is a complex type.
Without _.clone()_, calling _x.conversion_rate.map(...)_ would move the value out of _x.conversion_rate_.

If _x.conversion_rate_ is used later in the code, this would cause a compile-time error because the value has been moved.
Bigdecimal is a complex value as it represents arbitrary-precision decimal numbers.
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
where _as_ref()_ converts _Option<T> to Option<&T>_, allowing borrowing the value instead of moving or cloning it.
or 
```rust
let conversion_rate = currency
    .and_then(|x| x.conversion_rate)
    .map(|cr| cr.to_f64().expect("bigdecimal to f64"))
    .unwrap_or(1.0);
```
_and_then_ avoids intermediate map calls and also flattens the nested Option structure.

`let currency_name = ...` uses the same logic:
If no currency exists, the fallback is `.unwrap_or_else(|| "USD".to_string())`.
The same logic is for extracting _user_email_ and _country_ from the User object.

With similar logic I extract _Tax_ object based on the corresponding `order_id` and getting a `tax_rate` via `let tax_rate = taxes.map(|x| x.rate.to_f64().expect("tax rate bigdecimal to f64"));` with a descriptive error message - In case the conversion to _f64_ failed I know which field is responsible for that.


_CombinedOrder_ combines fields from both tables and includes a derived field _amount_with_tax_.
`o.amount * (1.0 + tax_rate),`

After all the fields are calculated, they are collected into the `Vec<CombinedOrderRecord>` via
`collect()`
The `.collect()` method collects all the `CombinedOrderRecord` instances into a new collection. The collection type depends on the type specified earlier in:
`let parquet_records: Vec<CombinedOrderRecord> = ...`

When I write the data into struct, in some cases it's `order_id: o.order_id,` in some `u.country.clone()`, why not clone all the time? Because `order_id` here is `i32` which implements `Copy` trait and `country` which is String - doesn't.

After this collection I need to write the file into parquet format and upload to S3. 
How to do it?
Now we have:

1.  Define the Path & get parquet_records of type **_CombinedOrderRecord_**

    ```rust
    let path = "/tmp/combined_orders.parquet";
    let path_meta = <&str>::clone(&path); 
    let mut count = 0;

    let parquet_records: Vec<CombinedOrderRecord> = orders
    ...
    ```

2.  Get the Schema

    ```rust
    let vector_for_schema = &parquet_records;
    let schema = vector_for_schema.as_slice().schema().unwrap();
    println!("{:?} schema", &schema);
    ```

    Here:
    `vector_for_schema` is now a reference to the vector `parquet_records`, meaning I can use it without moving ownership.
    
    `as_slice()` converts the vector reference into a slice (&[T]), allowing slice-based operations.
    `.schema()` is a method provided by a trait **_ParquetRecordWriter_**, which extracts the Parquet schema from the data structure (`schema()` returns `Result<parquet::schema::types::TypePtr, parquet::errors::ParquetError>`).
    `.unwrap()` is used to handle the Result type returned by `.schema()`, which will panic if the operation fails. If the schema extraction is successful, it returns the schema object.

3.  Open File for Writing

    ```rust
    let file = std::fs::File::create(path).unwrap();
    let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();
    ```

    `std::fs::File::create(path):`
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
    `-> Arc<WriterProperties>` This defines a public function named props that returns a reference-counted (Arc) instance of WriterProperties.
    _Arc_ stands for **_Atomic Reference Counting_**, which allows safe, shared ownership of data across multiple threads in a concurrent environment.
    **_WriterProperties_** is a struct from the **_parquet_** crate used to configure properties for writing Parquet files.
    
    _**WriterProperties::builder()**_  initializes a builder pattern for creating **_WriterProperties_** instances, which allows chaining of configuration methods.
    **_.set_compression(parquet::basic::Compression::GZIP)_** configures the writer to use **_GZIP_** compression for **_Parquet_** file output.
    **_parquet::basic::Compression::GZIP_** specifies GZIP as the compression codec.
    **_.build()_** finalizes and constructs an instance of **_WriterProperties_** with the specified settings.
    **_Arc::new(...)_** wraps the created **_WriterProperties_** inside an **_Arc_**, enabling shared ownership.
    
4.  Write Data to the File
    
    ```rust
    let mut row_group = pfile.next_row_group().unwrap();
    (&parquet_records[..])
        .write_to_row_group(&mut row_group)
        .expect("can't 'write_to_row_group' ...");
    pfile.close_row_group(row_group).unwrap();
    count += 1;
    println!("{} count", count);
    ```

    **_pfile.next_row_group():_**
    Prepares the next row group for writing.
    Row groups are logical blocks of rows within a Parquet file.
    **_write_to_row_group:_**
    Serializes the **_parquet_records_** and writes them to the current row group.
    Panics with a custom error message if writing fails.
    **_pfile.close_row_group(row_group):_**
    Closes the row group after writing.
    **_count:_**
    Tracks the number of row groups written.
    This code increments and prints it.
    
5.  Finalize the File
    `pfile.close().unwrap();`
    `.close()`: when writing data to a file, it is often buffered in memory before being written to disk.
    Calling `close()` ensures  that resources are properly released and all buffered data is written (flushed) to the file system, preventing data loss.
    
    
6. Read Metadata from the File for prometheus metrics
    
    ```rust
    let reader = SerializedFileReader::try_from(path_meta).unwrap();
    let parquet_metadata = reader.metadata();
    let file_metadata = parquet_metadata.file_metadata();
    let rows_number = file_metadata.num_rows();
    (path.into(), rows_number)
    ```

    **_SerializedFileReader::try_from(path_meta):_**
    Opens the written Parquet file for reading.
    Reads the file metadata for verification or further processing.
    **_file_metadata.num_rows():_**
    Retrieves the number of rows written to the file.
    **_(path.into(), rows_number):_**
    Returns the file path and the number of rows as the output of the task.

### Streaming Tasks

Because our program started from reading small-normal size tables we started using **_Diesel_**, but then we got hit by program getting OOM or getting into the conflict with RDS instance due to loading the huge volume of data at once from the big tables.
To handle that some tasks were recreated using **_sqlx_** crate, which was used for asynchronously reading large tables from a PostgreSQL, processing the data, and writing it to a Parquet file format.

Why Use **_sqlx_** Instead of diesel for Large Tables?

**Asynchronous Database Access (Key Advantage):** 

- **_sqlx_** provides **_async_**/**_await_** support, which allows for non-blocking database operations.
This is crucial for handling large datasets, as it enables efficient streaming and processing without blocking the main thread, improving throughput and scalability.
In contrast, _**diesel**_ primarily uses synchronous operations, which can cause blocking issues when working with large datasets.

**Efficient Streaming of Large Data:**

The code uses **_sqlx::query_as_** and **_.fetch(&pool)_** to stream results.
Streaming helps in processing large tables in chunks instead of loading everything into memory at once.

**Lightweight and Compile-time Checked Queries**

**_sqlx_** offers compile-time SQL query verification with strong typing, ensuring correctness and performance optimization at build time.
_**Diesel**_ often requires complex query-building and lacks full async support.

**Flexibility with Dynamic Queries**

_**sqlx**_ allows direct string-based SQL queries (**_query_as::<sqlx::Postgres, RequestRecordStream>(&query);_**), making it easier to work with dynamic queries.
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
where `WHERE 1=1` allows appending conditions without worrying about the first AND clause.
Conditions are added based on available filters (email, min_date). If additional filters are added, the query adapts accordingly.
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
So for each extra filter value in Diesel I need to write extra code, when for the each extra filter value in sqlx I just add the filter line to the code.

sqlx allows: 
- String-Based Query Construction: I can construct queries dynamically without predefined schema definitions.
- Flexibility with Input: Supports building queries based on user-provided filters without writing multiple query versions.
- No Compile-Time Schema Enforcement(very important if I want to check what I'm getting): Unlike Diesel, sqlx allows running ad-hoc queries without defining schema structs.

For **_sqlx_**  I have traits `ProjectStreamTask` and `HugeStreamTask`  which define an interface to run asynchronous tasks that interact with PostgreSQL and return results.
They enforce that implementing structs must be **_Send + Sync + Debug + UnwindSafe_**, ensuring thread safety and error resilience.
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
In the streaming task the **_RequestRecordStream_** struct, derived with **_ParquetRecordWriter_** and **_sqlx::FromRow_**, and **_Default_** and **_Debug_** which provide automatic implementations of functionalities that help with extracting struct field names, fetching data from Postgres and writing it to Parquet files.

**_sqlx::FromRow_**  derive macro enables the struct to be used with SQLx to map database query results directly into Rust structs.

It allows SQLx to deserialize rows from a database query into instances of **_RequestRecordStream_**.

For example, using this query SQLx will automatically map the database columns to the corresponding struct fields.
```
let result = sqlx::query_as::<sqlx::Postgres, RequestRecordStream>(&query).fetch(&pool);
```
**_ParquetRecordWriter_**  derive macro enables automatic writing of struct instances to Parquet files.

**_Default_** derive macro provides a way to create a default value for a struct (or other types) when no specific values are provided.

When the **_Default_** trait is derived, Rust will automatically generate an implementation for it that initializes all struct fields with their respective default values.
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
pub async fn requests(pg_uri: &str) -> anyhow::Result<(String, i64)> {
```
1. Connecting to PostgreSQL 
```rust
let pool = PgPool::connect(pg_uri).await?;
```

Creating a Placeholder Struct Instance: This creates a vector with a default instance of RequestRecordStream to:
- Simulate a dataset structure.
- Use it for schema introspection to dynamically build the query.
```rust
  let fake_requests = vec![RequestRecordStream {
    ..Default::default()
  }];

```
Why do I need this placeholder? Because this placeholder struct instance is used to introspect the schema of RequestRecordStream dynamically. In Rust, struct fields aren't accessible at runtime in the same way as in dynamic languages (e.g., Python). Instead, I need to create an instance of the struct to analyze its fields and types.
The struct **_RequestRecordStream_** is annotated with **_#[derive(ParquetRecordWriter, sqlx::FromRow)]._** These derive macros enable schema extraction.
Creating a default instance (**_..Default::default()_**) allows access to the schema, which is used later in the code to generate a list of database columns.

Since the struct fields represent database columns, creating an instance helps dynamically determine column names required for query building.
Without this, I would need to hard-code column names (like in the 'normal' tasks described above), which reduces flexibility.

The obvious advantages:
- If the struct definition changes (e.g., new fields are added), the introspection ensures that the SQL query automatically adapts, avoiding manual updates.
- the program avoids errors as without creating an instance, trying to access field names programmatically would lead to compilation errors because Rust’s type system doesn't allow reflection like dynamically typed languages.

Extracting Schema Information from the Struct
```rust
let vector_for_schema = &fake_requests;
let schema = vector_for_schema.as_slice().schema().unwrap();
let schema_2 = vector_for_schema.as_slice().schema().unwrap();
let schema_vec = schema_2.get_fields();
```
The code extracts schema details from the sample data.
**_vector_for_schema.as_slice().schema().unwrap()_** retrieves schema metadata, such as field names and types.
**_schema_vec = schema_2.get_fields();_** gets a list of fields (columns) for further processing.

Building Field Names for SQL Query
```rust
let mut fields: Vec<&str> = vec![];
for i in schema_vec {
    if i.name() == "uuid" {
        fields.push("uuid::varchar") // because parquet wasn't supporting uuid writing
    } else if .. {
        ... 
    } else {
        fields.push(i.name())
    }
}
println!("{:?} fields!", fields);
```
This loop iterates over all schema fields and dynamically constructs SQL-friendly field names:
- If the field is named _uuid_, it converts it to **_uuid::varchar_** to ensure proper type handling in SQL queries.
- Other fields are pushed as-is.
The final field list is printed for debugging purposes.

Setting Up Parquet File Writing
```rust
let requests_load = Instant::now();
let path = "/tmp/requests.parquet";
let path_meta = <&str>::clone(&path);

let file = std::fs::File::create(path).unwrap();
let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();
```
_**Instant::now()**_ tracks how long the operation takes.
A Parquet file path is defined as **_"/tmp/requests.parquet"_**.
The file is created using **_std::fs::File::create(path)_**.
A Parquet writer (_**SerializedFileWriter**_) is initialized with the schema and file properties.

Constructing the SQL Query
```rust
let table: &str = "requests";

let mut query = "SELECT ".to_owned();
let fields: &str = &fields.join(", ");
query.push_str(fields);
query.push_str(" FROM ");
query.push_str(table);
```
A _**SELECT**_ query is dynamically built by concatenating the extracted field names and ppending the table name (_requests_).

Query Execution with SQLX (**_query_as_**): Executes the SQL query asynchronously and streams results.

```rust
let result = sqlx::query_as::<sqlx::Postgres, RequestRecordStream>(&query);
let requests_stream = result.fetch(&pool);
```


Processing Data in Chunks (5000 rows at a time): Streams rows from the database and writes them to a Parquet file in chunks.
```rust
let mut chunk_stream = requests_stream.map(|fs| fs.unwrap()).chunks(5000);
while let Some(chunks) = chunk_stream.next().await {
    let mut row_group = pfile.next_row_group().unwrap();
    (&chunks[..])
        .write_to_row_group(&mut row_group)
        .expect("can't write_to_row_group");
    pfile.close_row_group(row_group).unwrap();
}
```

Trait Implementation (RequestStreamingTask): Implements the trait to run the task that fetches data and stores it.
```rust
#[async_trait]
impl ProjectStreamingTask for RequestStreamingTask {
    async fn run(&self, postgres_uri: &str) -> (String, i64) {
        requests(postgres_uri).await.unwrap()
    }
}
```

### Parquet Writer

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
Implements the FileWriterRows trait for `SerializedFileWriter<W>`, which is responsible for writing Parquet data to a file.
The issue: we used to have `&self.total_num_rows` from  `parquet::file::writer::SerializedFileWriter`
```rust
pub struct SerializedFileWriter<W: ParquetWriter> {
    buf: W,
    schema: TypePtr,
    descr: SchemaDescPtr,
    props: WriterPropertiesPtr,
    total_num_rows: i64,...
```
but after another crate update it became a private field so we lost access to it. TODO was to figure it out but at the end we just hardcoded a meaningless number.

5. Module: prelude
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

[//]: # ()
[//]: # (We used to have)

[//]: # (```rust)

[//]: # (let props = Arc::new&#40;WriterProperties::builder&#40;&#41;.build&#40;&#41;&#41;;)

[//]: # (let schema = inputs[0].1.file_metadata&#40;&#41;.schema_descr&#40;&#41;.root_schema_ptr&#40;&#41;;)

[//]: # (let mut writer = SerializedFileWriter::new&#40;output, schema, props&#41;?;)

[//]: # (```)

[//]: # (while using the previous version of parquet crate.)

[//]: # ()
[//]: # (This snippet sets up a Parquet file writer with the following:)

[//]: # ()
[//]: # (**_Properties &#40;props&#41;_**: Specifies settings like compression and encoding.)

[//]: # (**_Schema &#40;schema&#41;_**: Defines the structure of the data.)

[//]: # (**_File Writer &#40;writer&#41;_**: Prepares the output destination for writing Parquet data.)

[//]: # (This is the initialization step before writing rows of data into a Parquet file.)

[//]: # ()
[//]: # (Where:)

[//]: # (**_WriterProperties_** were used to configure properties for writing Parquet files.)

[//]: # (Common configurations include compression algorithms, encoding, and other optimizations.)

[//]: # (**_WriterProperties::builder&#40;&#41;_** provides a builder pattern to customize these properties.)

[//]: # ()
[//]: # (**_Arc::new&#40;...&#41;:_**: **_Arc_** stands for **_Atomic Reference Counting_**, a smart pointer for shared ownership across threads.)

[//]: # (In this case, it ensures that the **_WriterProperties_** can be shared safely if multiple threads are involved &#40;so different parts of my program &#40;running concurrently in separate threads&#41; might need to access and use the same instance of **_WriterProperties_**&#41;.)

[//]: # (The **_Arc_** wraps the **_WriterProperties_** object so it can be accessed concurrently in a thread-safe manner.)

[//]: # ()
[//]: # (in `let schema = inputs[0].1.file_metadata&#40;&#41;.schema_descr&#40;&#41;.root_schema_ptr&#40;&#41;;`)

[//]: # (_**inputs**_: is a collection holding data or file-related information.)

[//]: # (Accessing inputs[0].1 implies the structure is a tuple &#40;e.g., &#40;x, y&#41;&#41; where the second element &#40;1&#41; holds Parquet metadata or file-related information.)

[//]: # ()
[//]: # (_**file_metadata&#40;&#41;**_: retrieves metadata about the Parquet file, such as schema, row group details, and other properties.)

[//]: # (**_schema_descr&#40;&#41;_**:)

[//]: # ()
[//]: # (Returns a descriptor of the Parquet schema, which describes the structure of the data &#40;columns, types, etc.&#41;.)

[//]: # (_**root_schema_ptr&#40;&#41;**_: gets a pointer to the root schema of the Parquet file.)

[//]: # (This is required to define the structure of the output Parquet file.)

[//]: # ()
[//]: # (`let mut writer = SerializedFileWriter::new&#40;output, schema, props&#41;?;`)

[//]: # (**_SerializedFileWriter_**: a key component in the parquet crate for writing Parquet files.)

[//]: # (It handles the serialization of data into the Parquet file format.)

[//]: # ()
[//]: # (**_new&#40;&#41;_**: creates a new instance of the file writer.)

[//]: # (Takes the following arguments:)

[//]: # (**_output_**: The output destination where the Parquet file will be written. This could be a file, stream, or buffer.)

[//]: # (_**schema**_: The schema descriptor &#40;retrieved earlier&#41; that defines the structure of the data being written.)

[//]: # (**_props_**: The writer properties &#40;e.g., compression settings&#41; defined earlier.)

[//]: # (?: the ? operator propagates errors if any occur during the creation of the file writer avoiding unexpected panic. Requires `Result/Option` return: )

[//]: # (If the operation returns _**Ok&#40;value&#41;**_, it extracts the value and continues execution.)

[//]: # (If the operation returns **_Err&#40;error&#41;_**, it propagates the error to the calling function.)

[//]: # ()
[//]: # (The difference with possible usage of **_unwrap&#40;&#41;_** is that `unwrap&#40;&#41;` panics on Error:)

[//]: # ()
[//]: # (If the operation returns _**Ok&#40;value&#41;**_, it extracts the value and continues execution.)

[//]: # (If the operation returns **_Err&#40;error&#41;_**, it panics, terminating the program.)

After we defined the function `pub fn combined_orders()` we need to call/execute it. For that after the function we have: 

```rust
pub struct CombinedOrdersTask {}

impl ProjectTask for CombinedOrdersTask {
    fn run(&self, postgres_uri: &str) -> (String, i64) {
        combined_orders(postgres_uri)
    }
}
```
**_CombinedOrdersTask_** is an empty public struct, used as a unit struct to represent a specific task related to processing combined orders.
It acts as a concrete implementation of the **_ProjectTask_** trait.

The **_run_** function is implemented to execute the **_combined_orders_** function, which processes data from the PostgreSQL database.
It follows the **_ProjectTask_** trait signature (**_fn run(&self, postgres_uri: &str) -> (String, i64);_**).

where `ProjectTask` (defined in prelude in `mod.rs`) is:

```rust
pub trait ProjectTask: Sync + Send + RefUnwindSafe + UnwindSafe {
    fn run(&self, postgres_uri: &str) -> (String, i64);
}
```
What it does:

This defines a trait `ProjectTask` that any implementing type must satisfy.
Types implementing **_ProjectTask_** must:
- Be thread-safe (_**Sync and Send**_).
- Be safe to use across unwind boundaries (**_RefUnwindSafe and UnwindSafe_**).
- Provide a _**run**_ function with the specified signature, which takes a PostgreSQL connection string (**_postgres_uri_**) and returns a tuple **_(String, i64)_**.

This trait is used to define a shared interface for a family of tasks that can perform some operation and return results.

In `mod.rs` I also have a definition of async trait `ProjectStreamingTask` for the streaming tasks.

```rust
#[async_trait]
pub trait ProjectStreamingTask: Debug + Sync + Send + RefUnwindSafe + UnwindSafe {
    async fn run(&self, postgres_uri: &str) -> (String, i64);
}
```

Similar to **_ProjectTask_**, this defines a trait for asynchronous tasks.
The #[async_trait] attribute allows the run function to be an **_async fn_**, enabling asynchronous operations within the trait implementation.
It's  designed for streaming tasks that may involve asynchronous operations, such as reading data from a database, processing it, and returning results.
Types implementing this trait must also be thread-safe and debug-friendly.

<details>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css">
  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
  <script>hljs.highlightAll();</script>
  <summary>More details about <code><strong>Thread-Safe</strong></code> (Sync and Send) traits</summary>

  A type that implements <em>Send</em> can safely be transferred between threads.<br>
  For example, if a type is <em>Send</em>, it can be passed to a thread or moved into a thread pool for parallel execution.<br>
  Most primitive types in <em>Rust</em> (like integers and String) are <em>Send</em> by default. However, types that contain raw pointers or manage non-thread-safe resources might not be.<br>
  (Raw pointers in Rust are <em>*const T</em> (immutable) and <em>*mut T</em> (mutable). These are low-level constructs that provide direct memory access, similar to pointers in C or C++. Unlike Rust's references (&T and &mut T).<br>

  <code><strong>Raw pointers</strong></code>:<br> 
  <ul>Lack Safety Guarantees:<br>
    
  <li>They do not enforce borrow checking, lifetimes, or ownership rules.</li>
  <li>This means I can create dangling pointers, null pointers, or data races if not handled carefully.</li>
  <li>Use Cases:</li>
    
  Raw pointers are typically used in unsafe code for advanced scenarios, such as:<br>
  <li>Interfacing with C code.</li>
  <li>Optimizing performance when known that the operations are safe.</li>
  <li>Implementing custom data structures or memory allocators.</li>
  </ul>
  Example:
  <pre><code class="language-rust">
    let x = 1;
    let raw_ptr: *const i32 = &x;
    
    unsafe {
        println!("Value at raw pointer: {}", *raw_ptr); // Unsafe block is required
    }
  </code></pre>
    
  <strong><em>Non-Thread-Safe Resources</em></strong>
  <em>Non-thread-safe</em> resources are types or constructs that cannot safely be shared or accessed by multiple threads simultaneously. 
  These might include:<br>
    
  <em>Rc&lt;T&gt;(Reference Counted Smart Pointer)</em><br>
  <em>Rc&lt;T&gt;</em> provides shared ownership of a value but is not thread-safe because it doesn’t use atomic operations to manage the reference count.
  Instead, <em>Arc&lt;T&gt;</em> (atomic reference counter) is used for thread-safe shared ownership.
    
  Example:
  <pre><code class="language-rust">
  use std::rc::Rc;
  let data = Rc::new(42);
  let cloned = Rc::clone(&data); // Safe in a single-threaded context
  // Rc is NOT `Send`, so it cannot be shared between threads
  </code></pre>
    
  <strong><em>Unsafe Data Structures</em></strong>
  Structures that allow direct, uncontrolled access to their internals, like raw pointers or custom synchronization primitives without proper locking mechanisms.<br>
    
  Global state:<br>
  Global variables or mutable static variables can lead to data races if accessed without proper synchronization.<br>
  Example of Non-Thread-Safe Code:<br>
  <pre><code class="language-rust">
  use std::cell::RefCell;
  let data = RefCell::new(5);
  // RefCell is not thread-safe, so this would cause issues in a multi-threaded context
  *data.borrow_mut() = 10;
  </code></pre>

  <strong><em>Thread-Safe Alternatives</em></strong>
  For non-thread-safe types, Rust provides thread-safe alternatives:<br>
    
  Instead of <em>Rc&lt;T&gt;</em>: Use <em>Arc&lt;T&gt;</em> for thread-safe reference counting.
  Instead of <em>RefCell&lt;T&gt;</em>: Use <em>Mutex&lt;T&gt;</em> or <em>RwLock&lt;T&gt;</em> for synchronized interior mutability.
  Global State: Use <em>lazy_static</em> or <em>OnceCell</em> for safe initialization of global variables.
    
  <strong><em>Sync Trait</em></strong>

  A type that implements <em>Sync</em> can safely be shared between threads by reference.
    For example, if <em>T</em> is <em>Sync</em>, then <em>&T</em> (a shared reference to <em>T</em>) can be accessed by multiple threads simultaneously without issues.
    This requires that the type guarantees no race conditions or undefined behavior, even when accessed concurrently by multiple threads.<br>

  Thread-Safety in Practice<br>
  Types that implement both <em>Sync</em> and <em>Send</em> are considered thread-safe in Rust. This ensures that the type can be used safely in multi-threaded environments.<br>
  Example:
  <pre><code>
  use std::sync::Arc;
  use std::thread;
    
  let data = Arc::new(vec![1, 2, 3]); // `Arc` is thread-safe
  let data_clone = Arc::clone(&data);
    
  thread::spawn(move || {
    println!("{:?}", data_clone); // Safe because `Arc` is `Sync` and `Send`
  }).join().unwrap();
  </code></pre>

  Why Arc is Sync and Send<br>
  <em>Arc&lt;T&gt;</em> (Atomic Reference Counted) is a smart pointer in Rust used for shared ownership of a value in a thread-safe manner. It achieves this by using atomic operations to manage its reference count, making it safe for use across multiple threads.<br>
  How Sync Applies to <em>Arc&lt;T&gt;</em><br>
  A type T is Sync if it can be safely shared between threads by reference (&T).<br>
  <em>Arc&lt;T&gt;</em> is Sync because:
  <ul>
  <li>It ensures atomicity of its reference count updates.</li>
  <li>The underlying data is immutable (by default) or access to it is protected (e.g., using locks like Mutex or RwLock), preventing data races.</li>
  </ul>  
  How Send Applies to <em>Arc&lt;T&gt;</em>:<br>
  A type T is Send if it can be safely transferred between threads.<br>

<em>Arc&lt;T&gt;</em> is Send because:<br>
  <ul>
  <li>Its internal reference count is updated atomically, so moving it to another thread does not cause unsafe behavior.</li>
  <li>The ownership of the Arc pointer itself (not the underlying data) is transferred safely.</li>
  </ul>

</details>

<details>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css">
  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
  <script>hljs.highlightAll();</script>
  <summary>More details about <code><strong>Safe to Use Across Unwind Boundaries</strong></code></summary>


  <em><strong>Safe to Use Across Unwind Boundaries (RefUnwindSafe and UnwindSafe)</strong></em>

  What Are Unwind Boundaries?<br>
    
  In Rust, an unwind occurs when a panic happens and the program starts cleaning up by dropping variables and freeing resources.<br>
  Code that interacts with panics must ensure that resources are safely released and that the program can recover or terminate gracefully.<br>
    
  <em><strong>UnwindSafe Trait</strong></em>
    
  A type that implements <em>UnwindSafe</em> ensures that it remains in a valid state if a panic occurs while the type is being accessed or used.<br>
  For example, a struct that only contains primitive types or safe abstractions like <em>String</em> will be <em>UnwindSafe</em>.<br>
    
  <em><strong>RefUnwindSafe Trait</strong></em>
    
  A type that implements <em>RefUnwindSafe</em> guarantees that it can be safely accessed through a reference (<em>&T</em>) across an unwind boundary.<br>
  This is a stricter guarantee than <em>UnwindSafe</em> because it deals with shared references.<br>
    
  Practical Use of <em>Unwind</em> Safety<br>
    
  These traits are mainly used in scenarios where panics can happen but the program intends to recover gracefully, such as in:<br>
  <em>std::panic::catch_unwind:</em> A function that allows catching panics and continuing execution.
    
  <pre><code>
  use std::panic;
    
  let result = panic::catch_unwind(|| {
    println!("Before panic");
    panic!("Oops!");
  });
  match result {
    Ok(_) => println!("Code ran successfully"),
    Err(_) => println!("Caught a panic"),
  }
  </code></pre>
</details>


<strong>Summary</strong>
<em><strong>Thread-Safety (Sync and Send)</strong><em>:

Ensures a type can be safely transferred (Send) or shared (Sync) between threads without causing race conditions or undefined behavior.
Important for concurrent or parallel processing.

<em><strong>Unwind Safety (RefUnwindSafe and UnwindSafe)</strong><em>:

Ensures a type can be safely accessed or manipulated across panic boundaries.
Important for error handling and maintaining program integrity during panics.
By combining these guarantees, Rust ensures memory safety, thread safety, and robustness in concurrent and error-prone code.


After the file is written to parquet format it needed to be uploaded to S3 bucket.
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

Here is the [upload](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-upload_to_s3-rs) function

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
`aws_config::from_env()`: Loads AWS credentials and configuration (such as access keys, regions) from environment variables.
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
`.body(body.unwrap())`: Provides the file content as the body (using unwrap() to handle potential errors).
.send().await`: Sends the upload request asynchronously.

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

After uploading file to S3 we had to [crawl](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-create_crawler-rs) it with the Glue crawler, but initially had to create the function which would create crawler if it didn't exist.

What does this function do? 
- Loads AWS credentials and region configuration.
- Checks if an AWS Glue crawler with the given name exists.
- If the crawler exists, it logs a message.
- If the crawler does not exist, it creates a new crawler targeting an S3 path.
- Logs success or failure.

  1. Function Signature:
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

4. Checking if Crawler Exists:
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

6. Determining if Crawler Should Be Created:
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
- If the crawler does not exist (`_` case), it sets must_create to true, meaning a new crawler should be created.
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

If Crawler Exists: if the program logs that the crawler already exists.

7. Returning Success: `Ok(())`
The function returns successfully if all operations complete without error.

Then we need to start a crawler which was the tricky part: if the crawler has already started, it will produce an error and stop the program execution.
For that we added a part for [waiting](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-start_crawler-rs)) with up to 20 attempts until the crawler was ready,

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
It would happen as:
When I call `std::thread::sleep`, it blocks the entire OS thread, meaning that:

- The runtime cannot schedule other tasks on that thread while it's sleeping.
- This can cause a significant slowdown, especially if the number of available worker threads is limited.
- Other async tasks waiting to run may be delayed unnecessarily.

But if I use `tokio` then it as other async runtimes, uses a thread pool to run tasks concurrently.

[//]: # ()
[//]: # (While writing this I decided to check what other async runtimes are available in Rust and created a short summary. )
[//]: # (### Async Runtimes Comparison Summary)
[//]: # ()
[//]: # (| Runtime   | Best Use Case               | Key Feature                    | Ecosystem Support |)

[//]: # ()
[//]: # (|-----------|-----------------------------|--------------------------------|-------------------|)

[//]: # ()
[//]: # (| **Tokio**  | Web services, microservices  | Multi-threaded, feature-rich   | Excellent         |)

[//]: # ()
[//]: # (| **async-std** | CLI tools, general async apps | Standard library-like API     | Good              |)

[//]: # ()
[//]: # (| **smol**   | Lightweight, minimal apps    | Small footprint                | Moderate          |)

[//]: # ()
[//]: # (| **actix**  | Actor-based web apps         | Built-in actor model           | Great &#40;for web apps&#41; |)

[//]: # ()
[//]: # (| **bastion**| Fault-tolerant services      | Resilient supervision          | Moderate          |)

[//]: # ()
[//]: # (| **glommio**| High-performance I/O apps    | NUMA-aware runtime             | Specialized       |)
[//]: # ()
[//]: # ()
[//]: # (| **embassy**| Embedded/IoT devices         | no_std async support           | Specialized       |)

<details>
  <summary><strong><em>While writing this I decided to check what other async runtimes are available in Rust and created a short summary</em></strong></summary>
  <em>Comparison Summary</em>
  <table>
  <thead>
    <tr>
      <th>Runtime</th>
      <th>Best Use Case</th>
      <th>Key Feature</th>
      <th>Ecosystem Support</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>Tokio</strong></td>
      <td>Web services, microservices</td>
      <td>Multi-threaded, feature-rich</td>
      <td>Excellent</td>
    </tr>
    <tr>
      <td><strong>async-std</strong></td>
      <td>CLI tools, general async apps</td>
      <td>Standard library-like API</td>
      <td>Good</td>
    </tr>
    <tr>
      <td><strong>smol</strong></td>
      <td>Lightweight, minimal apps</td>
      <td>Small footprint</td>
      <td>Moderate</td>
    </tr>
    <tr>
      <td><strong>actix</strong></td>
      <td>Actor-based web apps</td>
      <td>Built-in actor model</td>
      <td>Great (for web apps)</td>
    </tr>
    <tr>
      <td><strong>bastion</strong></td>
      <td>Fault-tolerant services</td>
      <td>Resilient supervision</td>
      <td>Moderate</td>
    </tr>
    <tr>
      <td><strong>glommio</strong></td>
      <td>High-performance I/O apps</td>
      <td>NUMA-aware runtime</td>
      <td>Specialized</td>
    </tr>
    <tr>
      <td><strong>embassy</strong></td>
      <td>Embedded/IoT devices</td>
      <td>no_std async support</td>
      <td>Specialized</td>
    </tr>
  </tbody>
</table>

These examples show implementation of a simple asynchronous HTTP server using different Rust async runtimes. The example will handle incoming requests and respond with a simple message.<br>


1. <strong><em>Tokio</em></strong>
<pre><code class="language-rust">
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
</code></pre>

<em>Tokio</em> provides a powerful multi-threaded runtime.
Best for high-performance web applications.
Rich ecosystem with support for databases, networking, and concurrency utilities.
Uses tasks and an I/O driver to handle concurrency efficiently.<br>

2. <em>async-std</em>

<pre><code class="language-rust">
use async_std::net::TcpListener;
use async_std::prelude::*;

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
</code></pre>
<em>async-std</em> provides a standard library API for async programming.
Best for simpler async applications and CLI tools.
Has a simpler API compared to Tokio but less optimized for high throughput.
Built on top of <em>async-io</em>.<br>

3. <em>smol</em>
<pre><code class="language-rust">
use smol::net::TcpListener;
use smol::prelude::*;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    smol::block_on(async {
    let listener = TcpListener::bind("127.0.0.1:8080").await?;
    println!("Listening on port 8080...");

        while let Some(stream) = listener.incoming().next().await {
            let mut stream = stream?;
            smol::spawn(async move {
                let mut buffer = vec![0; 1024];
                stream.read(&mut buffer).await.unwrap();
                stream.write_all(b"HTTP/1.1 200 OK\r\n\r\nHello from Smol!").await.unwrap();
            }).detach();
        }
        Ok(())
    })
}
</code></pre>

<em>Smol</em> is minimal and designed for lightweight applications.
Great for embedded devices or minimal environments.
Fewer dependencies compared to <em>Tokio</em> and <em>async-std</em>.
Uses thread-pool only when necessary.<br>

4. <em>Actix</em>
<pre><code class="language-rust">
use actix_web::{web, App, HttpServer, Responder};

async fn hello() -> impl Responder {
    "Hello from Actix!"
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    HttpServer::new(|| App::new().route("/", web::get().to(hello)))
        .bind("127.0.0.1:8080")?
        .run()
        .await
    }
</code></pre>

<em>Actix</em> is actor-based and well-suited for highly concurrent web apps.
Excellent performance in handling web requests compared to other runtimes.
Built on Tokio but provides an abstraction layer with actors for better concurrency.
Has built-in middleware support for web development.<br>

5. <em>Bastion</em>
<pre><code class="language-rust">
use bastion::prelude::*;
use tokio::net::TcpListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::main]
async fn main() {
Bastion::init();
Bastion::start();

    let _ = Bastion::supervisor(|sp| {
        sp.children(|ch| {
            ch.with_exec(move |ctx| {
                async move {
                    let listener = TcpListener::bind("127.0.0.1:8080").await.unwrap();
                    while let Ok((mut socket, _)) = listener.accept().await {
                        socket.write_all(b"HTTP/1.1 200 OK\r\n\r\nHello from Bastion!").await.unwrap();
                    }
                    Ok(())
                }
            })
        })
    });

    Bastion::block_until_stopped();
}
</code></pre>

Bastion is designed for high availability and resilience using the supervisor model.
Provides built-in fault tolerance, restarts, and message passing.
Best for critical services that require fault isolation.<br>

6. <em>Glommio</em>
<pre><code class="language-rust">
use glommio::{net::TcpListener, LocalExecutor};

fn main() {
    let ex = LocalExecutor::default();
    ex.run(async {
    let listener = TcpListener::bind("127.0.0.1:8080").await.unwrap();
    while let Ok(mut stream) = listener.accept().await {
        stream.write_all(b"HTTP/1.1 200 OK\r\n\r\nHello from Glommio!").await.unwrap();
        }
    });
}
</code></pre>

Glommio is designed for high-performance workloads on NUMA architectures. (UMA (Non-Uniform Memory Access) awareness refers to optimizing software to efficiently utilize the architecture of modern multi-socket and multi-core systems where memory access times vary depending on the processor accessing it. )
It provides a thread-per-core model to minimize context switching.
Best for low-latency, high-throughput applications.<br>

7. <em>Embassy</em>
<pre><code class="language-rust">
#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_net::{tcp::TcpSocket, Stack};

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let mut stack = Stack::new();
    let socket = TcpSocket::new(&stack);
    socket.accept().await.unwrap();
    socket.write_all(b"Hello from Embassy!").await.unwrap();
}
</code></pre>

Embassy is a <em>no_std</em> async runtime for embedded systems.
Optimized for resource-constrained environments.
Requires specific hardware setups like RTOS or bare-metal.<br>

</details>


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
    pub flag_kevel: String,
    pub flag_netsuite: String,
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

Error Handling:
If a task fails, it's logged and reported to Sentry:
```rust
if result.is_err() {
    let message = format!("project GOT Panic! in {} file", name);
    sentry::capture_message(message.as_str(), sentry::Level::Warning);
}
```

`main()`
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
    
    create_crawler(CRAWLER_NAME_ONE.to_string(), s3_path, true)
    .await
    .expect("create crawler");
    start_crawler(CRAWLER_NAME_ONE.to_string(), true)
    .await
    .expect("start crawler");
}
```




[//]: # (####  Query:)

[//]: # ()
[//]: # (Using AWS Glue, I crawled the Parquet files to make them queryable. Athena was then used to query the data efficiently.)


## Pros of This ETL Approach

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

A lot of Rust learning :) 

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