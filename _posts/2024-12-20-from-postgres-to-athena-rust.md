---
layout: post
title: "From Postgres to Athena: Optimizing Workflows with Rust, Parquet, and S3"
date: 2024-12-17
img: rust3.png
tags: [Rust, AWS, S3, Postgres]
---


! Work in progress, many additions coming !


## Problem:

This project began several years ago as a solution to a pressing need for providing data for company reporting in the absence of an established ETL process. The production data resided in a Postgres RDS database, but generating reports directly from 
the primary instance was not feasible. Doing so would have imposed additional load on the main application and required additional roles to handle live production data.


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


![AWS Glue]({{site.baseurl}}/assets/img/glue.jpeg)

<div style="display: flex; align-items: center; gap: 10px;">


  <img src="{{site.baseurl}}/assets/img/kube.png" alt="Kubernetes" style="height: 100px;">


  <img src="{{site.baseurl}}/assets/img/rust1.png" alt="Rust" style="height: 100px;">


  <img src="{{site.baseurl}}/assets/img/s3.png" alt="AWS S3" style="height: 100px;">


  <img src="{{site.baseurl}}/assets/img/glue.jpeg" alt="AWS Glue" style="height: 100px;">


  <img src="{{site.baseurl}}/assets/img/athena.png" alt="AWS Athena" style="height: 100px;">


</div>


Instead of performing everything within Postgres, I built an ETL pipeline with Rust, AWS S3, GLue and Athena.


Thes Rust project was originally initiated by my colleague and Rust wizard, [Xavier](https://github.com/xrl). His guidance and expertise helped me not only get started with Rust but also truly appreciate its beauty, power, and advantages. Thanks to his mentorship, I’ve come to love working with Rust and have seen firsthand how it can transform complex workflows (or make it even more complex but very fast :smile: ) .


Here’s how it worked:


## Rust Program:

The program fetched data from Postgres, performed transformations (including derived fields and joins across tables), and saved the output in Parquet format.

Using Rust allowed me to optimize performance and maintain type safety by representing tables as Rust structs.

Rust's type-checking served as a robust safeguard for ensuring the integrity of production data. If the production system encountered any invalid values or NaNs, the Rust process would immediately detect the issue and send an error notification, helping to maintain data accuracy and reliability.


The Rust program was deployed in a Kubernetes environment using a Helm chart. The chart configured a service account with the appropriate role-based access to AWS services, including S3 and Glue. Additionally, the Helm chart utilized a Kubernetes secret to securely manage the connection credentials for the RDS instance, ensuring secure and efficient integration with the necessary resources.


Parquet Files on S3:


Transformed data was stored in an S3 bucket in a columnar Parquet format. This reduced storage costs and improved query efficiency.


AWS Glue + Athena:


AWS Glue was used to crawl the Parquet files on S3 and create metadata.

Athena provided a cost-efficient way to query the data using SQL. Bear in mind that Athena doesn't create real tables or materialized views, it only creates a metadata and reads everything from the file, stored in S3.
The reports leveraged Athena tables and views as the foundation for data visualization.
The cons of such approach is that it's possible to delete underlying file without getting any warnings/restrictions about dependant views, tables etc.
Athena also doesn't provide indexing as it's just a querying tool. It also doesn't support ***CREATE TABLE LIKE*** or ***DELETE FROM*** or ***UPDATE***, but it allows to give an access to query a table without a fear that the table would be dropped as behind a hood it's a file in s3.
AWS Glue provides a mechanism for partitioning and indexing with the limitations: 
- only partition column could be used as an index
- only integer and strings could be used as an index



Rust program had the next structure:


- project_aws

- project_cli

- project_kube

- project_extra_source

- project_insert_data

- project_parquet

- project_schemas

- project_tasks

- project_partition_dates    


Why this project structure?

It was designed to allow for the separation of tasks and crates in Cargo.toml. This separation enabled me to build and manage each component independently, avoiding unnecessary complexity and performance bottlenecks. It also provided better visibility into the performance of individual areas, making it easier to track and optimize each part of the system.


#### Struct/Table Representation in Rust are in **_project_schemas_**

In order to read the tables and perform some calculations and also to ensure type safety  I had to map each Postgres table to a corresponding Rust struct. Initially, this mapping was done manually, but later I discovered the powerful _**diesel_ext**_ crate (later _**diesel_cli_ext**_), which allowed me to automatically map the schema from Postgres to Rust structs. I still had to create diesel _table!_ macro definition which was done with the help of _bash_ script:

```commandline
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'orders';
```
which was giving me 
```shell
           column_name           |          data_type          | is_nullable 
---------------------------------+-----------------------------+-------------
 id                              | integer                     | NO
 active                          | boolean                     | NO
 name                            | character varying           | YES
 created_at                      | timestamp without time zone | NO
 data                            | jsonb                       | YES
 ...
```
which together with a bash script would give diesel _table!_ macro definition:
<div class="code-container">

  <script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=table_macro.sh"></script>

</div>

and the definition would be:
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


The create-model target in the _**Makefile**_ generates the necessary Rust files for each table. It begins by creating a _diesel.toml_ file for the table, which defines how the schema is printed.

The command then adds the module for the table to various locations in the project, including _**mod.rs**_ files for organizing the project’s code structure.

Using the _**diesel**_ print-schema command, the schema for the specified table is fetched from the local Postgres database and saved to a Rust file.

The _**diesel_ext**_ crate is then used to generate the Rust struct for that table, which is placed in the appropriate module.


I created also a _**template_task**_ which was a blue-print for most tasks and used the _**sed**_ command to customize tasks files (using [_**template_task**_](https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c#file-template_task-rs) ), creating a corresponding task in the project.

This streamlined the process significantly, allowing for efficient table mapping and the integration of the database schema into Rust code with minimal manual intervention.


Here’s the Makefile command that does all of this:


Makefile

<div class="code-container">

  <script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=create_model.rs"></script>

</div>


Test

<script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=create_model.rs"></script>


This approach saved considerable time and reduced the chance of errors with types/nullables by automating the mapping process.

Now I would rather put everything into combined bash script which would run over the predefined list of tables and create _table!_ macro definition and a corresponding struct with a task, but the existing approach worked well for years and I won't change it, as its life is coming to the end due to change in the infrastructure.
Here’s an example of the Postgres table, a corresponding struct and the task:


#### For instance, assume I had several postgres tables:


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

To combine these tables and add calculated fields, the Rust program used the following structs:


<script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=tables_structs.rs"></script>


The table and struct definitions were organized within the _project_schemas_ directory. This directory included the tables and models subdirectories, each housing the respective definitions. Additionally, a mod.rs file was used to list and manage all the tables and models for easier access and modularity.

```shell
project_schemas
├── tables
└── models
```

<div class="code-container">
    <script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=combined_orders.rs"></script>
</div>

Here:

_Order_ and _User_ represent the tables fetched from Postgres.
```shell
let products = products_dsl::products.load::<Product>(&conn).unwrap();
```
is part of a query using _Diesel_, an _ORM (Object-Relational Mapper)_ library for interacting with databases in Rust.
This line brings into scope the _DSLs (Domain-Specific Languages)_ for interacting with tables in the database. Diesel uses DSLs to generate SQL queries and map the results to Rust types. The products::dsl, orders::dsl, and users::dsl refer to the tables orders, users, and products respectively, and I'm giving them aliases (orders_dsl, users_dsl, products_dsl) for convenience.
_products_dsl::products_

_products_dsl_ is the alias I created for _products::dsl_. _Diesel_ automatically generates a _products_ variable (referring to the products table in the database) within this DSL module, which represents the table in the database.

``.load::<Product>()`` is a Diesel method used to execute the query and load the results into a collection of Rust structs `Vec<Product>`.

_Product_ is a _Rust_ struct representing the schema of the products table (i.e., it maps the columns of the _products_ table to fields in the _Product_ struct).

_&conn_ is a reference to a database connection, which is used to execute the query against the database. This connection is established using Diesel’s connection API (e.g., _PgConnection_ for PostgreSQL).

_.unwrap()_ is used to unwrap the _Result_ returned by ``load::<Product>()``. This method will either return the query results (if successful) or panic if there was an error.
Usually it is discouraged to use `unwrap` in production code unless I am  certain that the query will succeed, as it causes the program to panic on an error.
We were using `unwrap` as wanted the program to panic and stop running, which will give us a clear sign that the data is not updated.
If I implemented it now I will rather use `expect` with the custom message but keep the panicking behaviour.
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

Usually the `panic!()` was caused by changes in the underlying Postgres tables, like removed column, unexpected type etc. I couldn't dynamically construct a struct in Rust with Diesel - so if I had a column in my table! macro definition and a struct but `.load::<Product>` didn't find it - it will result in panic.
In that case running the task further which was loading this table didn't make sense hence `panic!()` behaviour was justified.


I wanted to see how long it takes to load some tables, for that I have
```rust
    let users_load = Instant::now();
    let users = users_dsl::users.load::<User>(&conn).unwrap();
    trace!("load users took: {:?}", users_load.elapsed());
```
where `Instant::now()` creates a new Instant that represents the current time, essentially starting a stopwatch.
`trace!` lane logs the time taken to execute the query and to load the table users from the database. It uses the trace! macro, which is typically used for logging at a fine-grained level (very detailed). The elapsed() duration is formatted and printed to show how long the query took to execute.
The elapsed() method in Rust returns a Duration object, which represents the amount of time that has passed since the Instant was created. The unit of time in Duration is typically in nanoseconds (ns).
This information could be useful for monitoring and optimization.
The duration could be converted to different units as 
```rust
println!("Elapsed time in milliseconds: {:?}", users_load.as_millis());
println!("Elapsed time in seconds: {:?}", users_load.as_secs());
println!("Elapsed time in microseconds: {:?}", users_load.as_micros());
```

I want to collect all users ids and also all product ids from the users table
```rust
let users_ids: Vec<i32> = users.iter().map(|x| x.id).collect();
trace!("{:?}", users_ids.len());
let products_ids: Vec<i32> = users.iter().filter_map(|x| x.product_id).collect();
```
`.map(|x| x.id)` takes every users record, extract value from the field `id` and collects them into a vector if integers `Vec<i32>`.

`users.iter().filter_map(|x| x.product_id).collect();` creates a vector (products_ids) that contains the product_id field of each user from the users vector, but only if product_id is Some(i32). The filter_map function filters out None values and collects only Some(i32) values into the vector. This results in a list of product_ids from users.

I want to get currency, correspoinding with the product_id so for that I load currencies table, filtering it by two fields: `type` and `type_id`

`.filter(currencies_dsl::type.eq("Product"))`
Filters the currencies table to only include rows where the type column is equal to "Product".
`.filter(currencies_dsl::type_id.eq(any(&products_ids[..])))`
Filters the currencies table to only include rows where the type_id column matches one of the product_ids from the users table.

_CombinedOrder_ combines fields from both tables and includes a derived field _amount_with_tax_.

This structured approach made the code cleaner and easier to maintain.

## ETL Workflow

#### Extract:

The Rust program connected to the Postgres RDS instance and read data from orders and users tables.


#### Transform:

Using the CombinedOrder struct, I combined and combined the data, e.g., calculating amount_with_tax.


#### Load:

Transformed data was written to S3 as Parquet files.


The project_aws module contains functions that define the AWS SDK provider for connecting to AWS services. It handles tasks such as loading and streaming data to S3, starting AWS Glue jobs, and managing the flow of data through these services.


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



Here is the upload function


<script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=upload_to_s3.rs"></script>)


These operations can take time, so rather than blocking the execution of the entire program while waiting for them to complete, I allow the program to continue doing other things while waiting for the results.

Later using these functions I got into some 'freeze' but I'll write about it later.


We also used to have

```rust
let credentials_provider = DefaultCredentialsProvider::new().map_err(Box::new)?
```

but later switched to `aws_config`


After uploading file to S3 we had to crawl it with the Glue crawler, but initially had to create the function which would create crawler if it didn't exist.


<script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=create_crawler.rs"></script>)


Then we need to start a crawler which was the tricky part: if the crawler has already started, it will produce an error and stop the program execution.

For that we added a part for waiting with up to 20 attempts until the crawler was ready,


<script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=start_crawler.rs"></script>)


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