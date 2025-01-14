---
layout: post
title: "From Postgres to Athena: Optimizing Workflows with Rust, Parquet, and S3"
date: 2024-12-17
img: rust3.png
tags: [Rust, AWS, S3, Postgres]
---
_Work in progress_
&nbsp;

## Problem:

This project began several years ago as a solution to a pressing need for providing data for company reporting in the absence of an established ETL process. The production data resided in a Postgres RDS database, but generating reports directly from 
the primary instance was not feasible. Doing so would have imposed additional load on the main application and required additional roles to handle live production data.

Moreover, we needed to perform complex computations and aggregations and store the processed results for subsequent use in reporting. While Postgres excels at handling transactional workloads, it posed some challenges when tasked with heavy computations and data enrichment.


## Security Concerns:

I did not want to give direct access to the Postgres RDS instance to other services or users. Instead, I wanted a secure and controlled way to read data, transform it, and expose only selected results. Access was restricted to calls made only via a program (like an API call) for security.


## Performance Issues:

Running complex calculations directly on the Postgres instance each time the user was opening the report or filtering it was affecting query performance for other critical workloads.


## Operational Complexity:

Incorporating derived fields and merging data from multiple tables resulted in overly complex schemas for views and queries, making them increasingly difficult to manage and maintain. Additionally, several machine learning computations needed to be performed on the production data, but running these directly on live data was not feasible.


## Cost Concerns:

Scaling the Postgres instance to handle heavy ETL (Extract, Transform, Load) processes was considered expensive at that time.


# The Solution: ETL with Rust + Parquet + S3 + Glue + Athena

{% mermaid %}
graph TD;
RustProgram[Rust Program] -->|Reads| PostgresRDS[PostgreSQL RDS];
RustProgram -->|Calculates & Aggregates| S3ParquetFiles[S3 Parquet Files];
AWS_GLUE[AWS Glue Crawler]-->|Crawls & Creates Schema| S3ParquetFiles[S3 Parquet Files];
S3ParquetFiles[S3 Parquet Files] -->|Tables via Glue Schema| AWSAthena[AWS Athena];
AWSAthena -->|Used in| Reports[Reports];

    %% Adding styles for clarity
    classDef process fill:#f9f,stroke:#333,stroke-width:2px;
    class RustProgram,PostgresRDS,S3ParquetFiles,AWS_GLUE,AWSAthena,Reports process;
{% endmermaid %}



Instead of performing everything within Postgres, we built an ETL pipeline with Rust, AWS S3, GLue and Athena.


This Rust project was originally initiated by my colleague and Rust wizard, [Xavier](https://github.com/xrl). His guidance and expertise helped me not only get started with Rust but also truly appreciate its beauty, power, and advantages. Thanks to his mentorship, I’ve come to love working with Rust and have seen firsthand how it can transform complex workflows (or make it even more complex but blazing fast :wink: ) .


Here’s how it worked:


## Rust Program:

The program fetched data from Postgres, performed transformations (including derived fields and joins across tables), and saved the output in Parquet format.

Using Rust allowed me to optimize performance and maintain type safety by representing tables as Rust structs.

Rust's type-checking served as a robust safeguard for ensuring the integrity of production data. If the production system encountered any invalid values or NaNs, the Rust process would immediately detect the issue and send an error notification, helping to maintain data accuracy and reliability.


The Rust program was deployed in a Kubernetes environment using a Helm chart. The chart configured a service account with the appropriate role-based access to AWS services, including S3 and Glue. Additionally, the Helm chart utilized a Kubernetes secret to securely manage the connection credentials for the RDS instance.


Parquet Files on S3:


Transformed data was stored in an S3 bucket in a columnar Parquet format. This reduced storage costs and improved query efficiency.


AWS Glue + Athena:


AWS Glue was used to crawl the Parquet files on S3 and create metadata.

Athena provided a cost-efficient way to query the data using SQL. Bear in mind that Athena doesn't create real tables or materialized views, it only creates a metadata and reads everything from the file, stored in S3.
The reports leveraged Athena tables and views as the foundation for data visualization.
The cons of such approach ate that it is possible to delete underlying file without getting any warnings/restrictions about dependant views, tables etc.
Athena also doesn't provide indexing as it's just a querying tool. It also doesn't support ***CREATE TABLE LIKE*** or ***DELETE FROM*** or ***UPDATE***, but it allows to give an access to query a table without a fear that the table would be dropped as behind a hood it's a file in s3.
AWS Glue provides a mechanism for partitioning and indexing with the limitations: 
- only partition column could be used as an index
- only integer and strings could be used as an index



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

It was designed to allow for the separation of tasks and crates in Cargo.toml. This separation enabled me to build and manage each component independently, avoiding unnecessary complexity and loading all the crates in once, each . It also provided better visibility into the performance of individual areas, making it easier to track and optimize and fix each part of the system.


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
let order_ids: Vec<i32> = users.iter().filter_map(|x| x.order_id).collect();
```
`.map(|x| x.id)` takes every users record, extract value from the field `id` and collects them into a vector if integers `Vec<i32>`.

`users.iter().filter_map(|x| x.order_id).collect();` creates a vector (order_ids) that contains the order_id field of each user from the users vector, but only if order_id is Some(i32). The filter_map function filters out None values and collects only Some(i32) values into the vector. This results in a list of order_ids from users.

I want to get currency, corresponding with the product_id so for that I load currencies table, filtering it by two fields: `type` and `type_id`

`users.iter()`

Creates an iterator over the users vector, producing references to each User object.
`.filter(currencies_dsl::type.eq("Order"))`
Filters the currencies table to only include rows where the type column is equal to "Order".
`.filter(currencies_dsl::type_id.eq(any(&order_ids[..])))`
Filters the currencies table to only include rows where the type_id column matches one of the order_ids from the users table.

Now I want to have a HashMap where keys are `order_id` and the values are references to the corresponding Currency objects.

```rust
let currencies_by_order_id: HashMap<i32, &Currency> = currencies
    .iter()
    .map(|x| (x.type_id.unwrap(), x))
    .collect();
```
`currencies.iter()`

Creates an iterator over the currencies vector, producing references to each Currency object.

`map(|x| (x.type_id.unwrap(), x))`

For each Currency object x:
`x.type_id.unwrap()` retrieves the `type_id` value from the `Option<i32>`. This assumes that all `type_id` values are Some and will panic if any type_id is None.
The closure returns a tuple (type_id, x), where type_id becomes the key and x (a reference to the Currency object) becomes the value.

`collect()`

Converts the iterator of (key, value) pairs into a HashMap.

`HashMap<i32, &Currency>`

The resulting HashMap has:
Keys of type i32, representing the unwrapped type_id values.
Values of type &Currency, which are references to the Currency objects.

Which creates kind of lookup table, when I can pass a key (type_id = order_id in our case) and get a corresponding Currency object with all the fields.

_CombinedOrder_ combines fields from both tables and includes a derived field _amount_usd_ using the information from currencies table and _amount_with_tax_ using the information from taxes table.

`orders.iter().filter(|order| order.user_id.is_some())` filters out orders where the user_id is None. This ensures only orders associated with a user are processed further.

The `.map(|o| { ... })` transforms each filtered order (o) into a new representation, producing a `CombinedOrderRecord`.
`let currency = currencies_by_order_id_id.get(&o.id)` retrieves the currency information for the current order from the `currencies_by_order_id_id` `HashMap` mapping described above, using the order's id as a key. If no entry exists, currency is None.
`let conversion_rate = ...` extracts the conversion rate from the currency (if it exists). 
The logic:
`currency.map(|x| ...)` operates on the optional currency object.
If a currency exists, its `conversion_rate` is cloned and converted to an f64. 
If this fails, an `expect` statement ensures a panic with an error message.
If no currency exists (`currency.is_none()`), a default conversion rate of `1.0` is used via `.unwrap_or(1.0)`.
`let currency_name = ...` uses the same logic:
If no currency exists, the fallback is `.unwrap_or_else(|| "USD".to_string())`.

With similar logic I extract Tax object based on the corresponding `order_id` and getting a `tax_rate` via `let tax_rate = taxes.map(|x| x.rate.to_f64().expect("tax rate bigdecimal to f64"));` with a descriptive error message - In case the conversion to f64 failed I know which field is responsible for that.


_CombinedOrder_ combines fields from both tables and includes a derived field _amount_with_tax_.

After I calculated all the fields, I'm collecting all data into the `Vec<CombinedOrderRecord>` via
`collect()`
The `.collect()` method collects all the `CombinedOrderRecord` instances into a new collection. The collection type depends on the type specified earlier in the chain. In this case, it’s a `Vec<CombinedOrderRecord>` as defined in:
`let parquet_records: Vec<CombinedOrderRecord> = ...`

After this collection I need to write the file into parquet format and upload to S3. 
Here we come to the part: why we have `use super::prelude::*;` at the top of `combined_orders.rs` task.

What it does:

This imports all public items from the prelude module defined in the parent module (super).
The * wildcard includes everything that is publicly available within the prelude module.
Purpose:

This is a common Rust pattern used to create a "prelude" module that contains frequently used imports, making them available to other parts of the codebase without needing repetitive use statements.
Example:

In my prelude module, I have imports like `std::time::Instant, diesel::prelude::*, bigdecimal, rayon::prelude::*`, etc. By doing `use super::prelude::*;`, my `combined_orders.rs` file can directly use these items without specifying them individually.

prelude mode looks like 

<div class="code-container">

  <script src="https://gist.github.com/kraftaa/1c60a3652d85aee34d53a4ca10f7a80c.js?file=tasks_mod.rs"></script>

</div>

which means I can use all public items from this module.
Where
The line `pub use ::function_name::named;` refers to re-exporting the named macro or function from the external crate function_name. Here's what it does:

`function_name` Crate
The `function_name` crate provides a procedural macro to retrieve the name of the current function at runtime in Rust. It is often used for logging, debugging, or tracing purposes.

named Macro
The named macro is a part of the function_name crate. It allows me to annotate a function so that I can programmatically access its name as a string during runtime.

When I apply `#[named]` to a function, it makes the name of the function accessible via a special constant or variable, usually _function_name.
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
In `mod.rs` I also have 
```rust
mod combined_orders; 
pub use self::combined_orders::*;
```
What it does:

`pub use self::combined_orders::*;` re-exports all public items from the combined_orders module, making them available to other parts of the codebase that import this parent module.
Purpose:

This pattern is often used in a module hierarchy to provide a clean interface to submodules by selectively exposing their contents.

In addition I also have
```rust
pub trait ProjectTask: Sync + Send + RefUnwindSafe + UnwindSafe {
fn run(&self, postgres_uri: &str) -> (String, i64);
}
```
What it does:

This defines a trait `ProjectTask` that any implementing type must satisfy.
Types implementing ProjectTask must:
Be thread-safe (Sync and Send).
Be safe to use across unwind boundaries (RefUnwindSafe and UnwindSafe).
Provide a run function with the specified signature, which takes a PostgreSQL connection string (postgres_uri) and returns a tuple (String, i64).
Purpose:

Traits like this are often used to define a shared interface for a family of tasks that can perform some operation (e.g., database processing) and return results.

and
```rust
#[async_trait]
pub trait ProjectStreamingTask: Debug + Sync + Send + RefUnwindSafe + UnwindSafe {
async fn run(&self, postgres_uri: &str) -> (String, i64);
}
```
What it does:

Similar to ProjectTask, this defines a trait for asynchronous tasks.
The #[async_trait] attribute allows the run function to be an async fn, enabling asynchronous operations within the trait implementation.
Purpose:

This trait is designed for streaming tasks that may involve asynchronous operations, such as reading data from a database, processing it, and returning results.
Types implementing this trait must also be thread-safe and debug-friendly.


More details about `Thread-Safe` (Sync and Send) traits:
`Send Trait`
A type that implements `Send` can safely be transferred between threads.
For example, if a type is `Send`, it can be passed to a thread or moved into a thread pool for parallel execution.
Most primitive types in Rust (like integers and String) are Send by default. However, types that contain raw pointers or manage non-thread-safe resources might not be.
(Raw pointers in Rust are *const T (immutable) and *mut T (mutable). These are low-level constructs that provide direct memory access, similar to pointers in C or C++. Unlike Rust's references (&T and &mut T).
Raw pointers: 
Lack Safety Guarantees:

They do not enforce borrow checking, lifetimes, or ownership rules.
This means I can create dangling pointers, null pointers, or data races if not handled carefully.
Use Cases:

- Raw pointers are typically used in unsafe code for advanced scenarios, such as:
- Interfacing with C code.
- Optimizing performance when known that the operations are safe.
- Implementing custom data structures or memory allocators.)

Example:
```rust
let x = 1;
let raw_ptr: *const i32 = &x;

unsafe {
    println!("Value at raw pointer: {}", *raw_ptr); // Unsafe block is required
}
```

Non-Thread-Safe Resources
Non-thread-safe resources are types or constructs that cannot safely be shared or accessed by multiple threads simultaneously. These might include:

Rc<T> (Reference Counted Smart Pointer)
Rc<T> provides shared ownership of a value but is not thread-safe because it doesn’t use atomic operations to manage the reference count.
Instead, Arc<T> (atomic reference counter) is used for thread-safe shared ownership.

Example:
```rust
use std::rc::Rc;

let data = Rc::new(42);

let cloned = Rc::clone(&data); // Safe in a single-threaded context
// Rc is NOT `Send`, so it cannot be shared between threads
```

Unsafe Data Structures
Structures that allow direct, uncontrolled access to their internals, like raw pointers or custom synchronization primitives without proper locking mechanisms.
Global State
Global variables or mutable static variables can lead to data races if accessed without proper synchronization.
Example of Non-Thread-Safe Code:
```rust
use std::cell::RefCell;

let data = RefCell::new(5);
// RefCell is not thread-safe, so this would cause issues in a multi-threaded context
*data.borrow_mut() = 10;
```

Thread-Safe Alternatives
For non-thread-safe types, Rust provides thread-safe alternatives:

Instead of Rc<T>: Use Arc<T> for thread-safe reference counting.
Instead of RefCell<T>: Use Mutex<T> or RwLock<T> for synchronized interior mutability.
Global State: Use lazy_static or OnceCell for safe initialization of global variables.

`Sync Trait`
A type that implements `Sync` can safely be shared between threads by reference.
For example, if `T` is `Sync`, then `&T` (a shared reference to `T`) can be accessed by multiple threads simultaneously without issues.
This requires that the type guarantees no race conditions or undefined behavior, even when accessed concurrently by multiple threads.
Thread-Safety in Practice
Types that implement both Sync and Send are considered thread-safe in Rust. This ensures that the type can be used safely in multi-threaded environments.
Example:
```rust
use std::sync::Arc;
use std::thread;

let data = Arc::new(vec![1, 2, 3]); // `Arc` is thread-safe
let data_clone = Arc::clone(&data);

thread::spawn(move || {
    println!("{:?}", data_clone); // Safe because `Arc` is `Sync` and `Send`
}).join().unwrap();
```
Why Arc is Sync and Send
Arc<T> (Atomic Reference Counted) is a smart pointer in Rust used for shared ownership of a value in a thread-safe manner. It achieves this by using atomic operations to manage its reference count, making it safe for use across multiple threads.

How Sync Applies to Arc<T>
A type T is Sync if it can be safely shared between threads by reference (&T).
Arc<T> is Sync because:
It ensures atomicity of its reference count updates.
The underlying data is immutable (by default) or access to it is protected (e.g., using locks like Mutex or RwLock), preventing data races.
How Send Applies to Arc<T>
A type T is Send if it can be safely transferred between threads.
Arc<T> is Send because:
Its internal reference count is updated atomically, so moving it to another thread does not cause unsafe behavior.
The ownership of the Arc pointer itself (not the underlying data) is transferred safely.

We used to have 
```rust
let props = Arc::new(WriterProperties::builder().build());
let schema = inputs[0].1.file_metadata().schema_descr().root_schema_ptr();
let mut writer = SerializedFileWriter::new(output, schema, props)?;
```
while using the previous version of parquet crate.

This snippet sets up a Parquet file writer with the following:

Properties (props): Specifies settings like compression and encoding.
Schema (schema): Defines the structure of the data.
File Writer (writer): Prepares the output destination for writing Parquet data.
This is typically the initialization step before writing rows of data into a Parquet file.

Where
WriterProperties:

This object is used to configure properties for writing Parquet files.
Common configurations include compression algorithms, encoding, and other optimizations.
WriterProperties::builder() provides a builder pattern to customize these properties.
Arc::new(...):

Arc stands for Atomic Reference Counting, a smart pointer for shared ownership across threads.
In this case, it ensures that the WriterProperties can be shared safely if multiple threads are involved.
The Arc wraps the WriterProperties object so it can be accessed concurrently in a thread-safe manner.

in `let schema = inputs[0].1.file_metadata().schema_descr().root_schema_ptr();`
inputs:

inputs seems to be a collection (likely a vector or similar structure) holding data or file-related information.
Accessing inputs[0].1 implies the structure is a tuple (e.g., (x, y)) where the second element (1) holds Parquet metadata or file-related information.
file_metadata():

Retrieves metadata about the Parquet file, such as schema, row group details, and other properties.
schema_descr():

Returns a descriptor of the Parquet schema, which describes the structure of the data (columns, types, etc.).
root_schema_ptr():

Gets a pointer to the root schema of the Parquet file.
This is required to define the structure of the output Parquet file.

`let mut writer = SerializedFileWriter::new(output, schema, props)?;`
SerializedFileWriter:

A key component in the parquet crate for writing Parquet files.
It handles the serialization of data into the Parquet file format.
new:

Creates a new instance of the file writer.
Takes the following arguments:
output: The output destination where the Parquet file will be written. This could be a file, stream, or buffer.
schema: The schema descriptor (retrieved earlier) that defines the structure of the data being written.
props: The writer properties (e.g., compression settings) defined earlier.
?:

The ? operator propagates errors if any occur during the creation of the file writer. If no errors occur, execution continues.

Now we are using 
1. Define the Path & get parquet_records of type CombinedOrderRecord
```rust
let path = "/tmp/combined_orders.parquet";
let path_meta = <&str>::clone(&path);   let vector_for_schema = &parquet_records;
let mut count = 0;

let parquet_records: Vec<CombinedOrderRecord> = orders
...
;

2. Get the Schema
```rust
let vector_for_schema = &parquet_records;
let schema = vector_for_schema.as_slice().schema().unwrap();
println!("{:?} schema", &schema);
```

3. Open File for Writing
```rust
let file = std::fs::File::create(path).unwrap();
let mut pfile = SerializedFileWriter::new(file, schema, props()).unwrap();
```
std::fs::File::create(path):
Opens the specified file for writing.
Creates the file if it doesn't already exist.
Panics on failure.
SerializedFileWriter::new(file, schema, props()):
Initializes a Parquet file writer.
Takes the file, schema, and writer properties (props()) as inputs.
props(): Presumably refers to writer properties like compression or encoding. If missing, it needs to be properly defined elsewhere.

4. Write Data to the File
```rust
let mut row_group = pfile.next_row_group().unwrap();
(&parquet_records[..])
    .write_to_row_group(&mut row_group)
    .expect("can't 'write_to_row_group' ...");
pfile.close_row_group(row_group).unwrap();
count += 1;
println!("{} count", count);
```

pfile.next_row_group():
Prepares the next row group for writing.
Row groups are logical blocks of rows within a Parquet file.
write_to_row_group:
Serializes the parquet_records and writes them to the current row group.
Panics with a custom error message if writing fails.
pfile.close_row_group(row_group):
Closes the row group after writing.
count:
Tracks the number of row groups written.
This code increments and prints it.

5.  Finalize the File
`pfile.close().unwrap();`

6.Read Metadata from the File

```rust
let reader = SerializedFileReader::try_from(path_meta).unwrap();
let parquet_metadata = reader.metadata();
let file_metadata = parquet_metadata.file_metadata();
let rows_number = file_metadata.num_rows();
(path.into(), rows_number)
```
SerializedFileReader::try_from(path_meta):
Opens the written Parquet file for reading.
Reads the file metadata for verification or further processing.
file_metadata.num_rows():
Retrieves the number of rows written to the file.
(path.into(), rows_number):
Returns the file path and the number of rows as the output of the task.


parquet_records: A collection of records (of type CombinedOrderRecord) that you want to write to the Parquet file.
vector_for_schema.as_slice(): Converts the Vec of records into a slice.
schema(): Derives the schema from the slice. This step retrieves the structure of the data to define how it will be serialized into the Parquet format.
unwrap(): Ensures that the schema extraction succeeds; if it doesn't, the program panics.
println!: Prints the schema for debugging or informational purposes.


Safe to Use Across Unwind Boundaries (`RefUnwindSafe and UnwindSafe`)
What Are Unwind Boundaries?
In Rust, an unwind occurs when a panic happens and the program starts cleaning up by dropping variables and freeing resources.
Code that interacts with panics must ensure that resources are safely released and that the program can recover or terminate gracefully.
UnwindSafe Trait
A type that implements UnwindSafe ensures that it remains in a valid state if a panic occurs while the type is being accessed or used.
For example, a struct that only contains primitive types or safe abstractions like String will be UnwindSafe.
RefUnwindSafe Trait
A type that implements RefUnwindSafe guarantees that it can be safely accessed through a reference (&T) across an unwind boundary.
This is a stricter guarantee than UnwindSafe because it deals with shared references.
Practical Use of Unwind Safety
These traits are mainly used in scenarios where panics can happen but the program intends to recover gracefully, such as in:
std::panic::catch_unwind: A function that allows catching panics and continuing execution.
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
Summary
`Thread-Safety (Sync and Send)`:

Ensures a type can be safely transferred (Send) or shared (Sync) between threads without causing race conditions or undefined behavior.
Important for concurrent or parallel processing.

`Unwind Safety (RefUnwindSafe and UnwindSafe)`:

Ensures a type can be safely accessed or manipulated across panic boundaries.
Important for error handling and maintaining program integrity during panics.
By combining these guarantees, Rust ensures memory safety, thread safety, and robustness in concurrent and error-prone code.

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