From Postgres to Athena: Optimizing Workflows with Rust, Parquet, and S3

Table of Contents





The Data Warehouse Dilemma
1.1. Security Concerns
1.2. Performance Issues
1.3. Operational Complexity
1.4. Cost Concerns



Choosing Rust for ETL
2.1. Context and Alternatives
2.2. Type Safety from Database to Code
2.3. Challenges and Annoyances



Building a Cloud-Native ETL Pipeline
3.1. ETL Overview
3.2. Rust and Diesel for Postgres Interaction
3.3. Leveraging Rust’s Type System
3.4. Parquet File Generation
3.5. S3 Upload and AWS Integration
3.6. Project Structure and Workflow



Deep Dive into the Rust Implementation
4.1. Schema Definition
4.2. Task Management
4.3. Streaming Tasks
4.4. Thread Safety in Rust
4.5. Parquet Writer Implementation



AWS Integration
5.1. S3 Upload Process
5.2. AWS Glue Crawler



Executing the ETL Program



Retrospective and Lessons Learned



Conclusion

1. The Data Warehouse Dilemma

Our journey began several years ago as a solution for providing data for company reporting in the absence of an established ETL process. The production data resided in a Postgres RDS database, but generating reports directly from the primary instance was not considered as an option. This decision was driven by several key factors:

1.1. Security Concerns

We faced strict limitations on direct access to the Postgres RDS instance. Our goal was to implement a secure and controlled method for reading data, transforming it, and exposing only selected results. Access was restricted to calls made via a program (API calls) for enhanced security. This approach ensured that sensitive data remained protected and only authorized processes could interact with the production database.

1.2. Performance Issues

Running complex calculations directly on the Postgres instance each time a user opened or filtered a report significantly impacted query performance for the main application. This approach was unsustainable as it affected the core business operations. We needed a solution that could offload these heavy computations from the primary database, allowing it to focus on its main transactional responsibilities.

1.3. Operational Complexity

Incorporating derived fields and merging data from multiple tables resulted in overly complex schemas for views and queries. This complexity made them increasingly difficult to manage and maintain. Additionally, several machine learning computations needed to be performed on the production data, but running these directly on live data was not feasible. We needed a way to denormalize and precompute certain data points without cluttering our production database schema.

1.4. Cost Concerns

Scaling the Postgres instance to handle heavy ETL (Extract, Transform, Load) processes was considered expensive at that time. We needed a solution that could efficiently process large volumes of data without requiring significant upgrades to our existing database infrastructure.

2. Choosing Rust for ETL

2.1. Context and Alternatives

When we started this project, the landscape of ETL tools was different from today. Spark ETL was considered but deemed too heavy for our use case. It would have required significant infrastructure overhead and introduced complexities in deployment and maintenance. dbt didn’t exist yet, and we needed a solution that could provide strong type safety and performance.

We also considered Python-based solutions, but we were concerned about runtime errors and the lack of compile-time guarantees. Our team had experience with statically-typed languages, and we wanted to leverage that for building a robust ETL pipeline.

2.2. Type Safety from Database to Code

Rust’s strong type system allows us to represent tables as Rust structs, providing compile-time guarantees about our data structures. This approach pushes many potential errors to compile-time, reducing runtime exceptions. Here’s an example of how we represent a table in Rust:

#[derive(Queryable, Debug)]
pub struct Order {
pub id: i32,
pub user_id: Option<i32>,
pub amount: BigDecimal,
pub created_at: Option<NaiveDateTime>,
pub uuid: Uuid,
}


This struct definition ensures that our code accurately reflects the database schema. If there’s a mismatch between the struct and the actual table structure, we’ll catch it at compile-time rather than encountering a runtime error.

For handling monetary values, we use the BigDecimal type:

use bigdecimal::BigDecimal;

#[derive(Queryable, Debug)]
pub struct Product {
pub id: i32,
pub name: String,
pub price: BigDecimal,
}


BigDecimal is commonly used in cases where floating-point precision is not enough, especially for financial calculations where exactness is crucial.

2.3. Challenges and Annoyances

While Rust has served us well, it’s not without its pain points:





Steep learning curve for team members new to Rust



Frequent battles with the borrow checker, especially in async contexts



Difficulty in upgrading Rust versions due to dependencies



Verbose error handling compared to languages with exceptions



Limited ecosystem for data processing compared to Python or Java

Despite these challenges, the benefits of using Rust, particularly in terms of performance and type safety, have outweighed the drawbacks for our use case.

3. Building a Cloud-Native ETL Pipeline

3.1. ETL Overview

Our ETL pipeline fetches data from Postgres, performs transformations (including derived fields and joins across tables), and saves the output in Parquet format. This process is deployed in a Kubernetes environment using a Helm chart. Here’s a high-level overview of our pipeline:

graph TD
A[Postgres RDS] -->|Fetch Data| B[Rust ETL Process]
B -->|Transform| C[Generate Parquet Files]
C -->|Upload| D[S3 Bucket]
D -->|Crawl| E[AWS Glue Crawler]
E -->|Create/Update| F[Athena Tables]
F -->|Query| G[Reporting Tools]


3.2. Rust and Diesel for Postgres Interaction

We use the Diesel ORM for database interactions. It provides type-safe database operations and query building. Here’s an example of how we fetch data:

let orders = orders_dsl::orders
.filter(orders_dsl::created_at.gt(some_date))
.load::<Order>(&conn)?;


This query is checked at compile-time, ensuring that the columns and types match our Order struct definition.

3.3. Leveraging Rust’s Type System

Rust’s type system and procedural macros do much of the heavy lifting in our ETL process:

#[derive(Queryable)]
struct Order { /* ... */ }

#[derive(ParquetRecordWriter)]
struct OrderParquet { /* ... */ }

// Transformation loop
for order in orders {
let parquet_order = OrderParquet::from(order);
writer.write(parquet_order)?;
}


The ParquetRecordWriter derive macro generates code for efficiently writing our data to Parquet format, reducing the chance of errors in the serialization process.

3.4. Parquet File Generation

We use the parquet crate to generate Parquet files. Here’s a simplified example of how we set up a Parquet writer:

use parquet::file::properties::WriterProperties;
use parquet::file::writer::SerializedFileWriter;

let file = std::fs::File::create(path)?;
let props = WriterProperties::builder()
.set_compression(Compression::SNAPPY)
.build();
let schema = get_schema(); // Define your Parquet schema
let mut writer = SerializedFileWriter::new(file, schema, Arc::new(props))?;

// Write data to Parquet file
// ...

writer.close()?;


3.5. S3 Upload and AWS Integration

After generating the Parquet files, we upload them to S3 using the rusoto_s3 crate:

use rusoto_s3::{PutObjectRequest, S3Client, S3};

async fn upload(path: &str, bucket: &str, key: &str) -> Result<(), Box<dyn Error>> {
let client = S3Client::new(Region::UsEast1);
let body = ByteStream::from_path(Path::new(path)).await?;

    let req = PutObjectRequest {
        bucket: bucket.to_string(),
        key: key.to_string(),
        body: Some(body),
        ..Default::default()
    };

    client.put_object(req).await?;
    Ok(())
}


3.6. Project Structure and Workflow

Our project follows a workspace structure, which allows for better organization and parallel builds:

etl-project/
├── Cargo.toml
├── etl-core/
│   ├── Cargo.toml
│   └── src/
├── etl-postgres/
│   ├── Cargo.toml
│   └── src/
└── etl-parquet/
├── Cargo.toml
└── src/


This structure helps us manage dependencies more effectively and keeps our codebase modular.

4. Deep Dive into the Rust Implementation

4.1. Schema Definition

We use Diesel’s schema definition to map our database tables to Rust structs:

table! {
orders (id) {
id -> Int4,
user_id -> Nullable<Int4>,
amount -> Numeric,
created_at -> Nullable<Timestamp>,
uuid -> Uuid,
}
}


This schema definition is used by Diesel to generate the appropriate SQL queries and ensure type safety.

4.2. Task Management

We implement a task system to manage different ETL operations:

pub trait Task: Send + Sync + RefUnwindSafe {
fn run(&self) -> Result<(), Box<dyn Error>>;
fn name(&self) -> &'static str;
}

pub struct TaskRunner {
tasks: Vec<Box<dyn Task>>,
}

impl TaskRunner {
pub fn new() -> Self {
TaskRunner { tasks: Vec::new() }
}

    pub fn add_task(&mut self, task: Box<dyn Task>) {
        self.tasks.push(task);
    }

    pub fn run_tasks(&self) -> Result<(), Box<dyn Error>> {
        for task in &self.tasks {
            task.run()?;
        }
        Ok(())
    }
}


4.3. Streaming Tasks

For handling large datasets, we implement streaming tasks:

pub trait StreamingTask: Send + Sync + RefUnwindSafe {
fn process_chunk(&self, chunk: &[u8]) -> Result<(), Box<dyn Error>>;
fn name(&self) -> &'static str;
}

pub struct StreamingTaskRunner {
tasks: Vec<Box<dyn StreamingTask>>,
}

impl StreamingTaskRunner {
pub fn new() -> Self {
StreamingTaskRunner { tasks: Vec::new() }
}

    pub fn add_task(&mut self, task: Box<dyn StreamingTask>) {
        self.tasks.push(task);
    }

    pub fn run_tasks(&self, reader: &mut dyn Read) -> Result<(), Box<dyn Error>> {
        let mut buffer = [0; 4096];
        loop {
            let bytes_read = reader.read(&mut buffer)?;
            if bytes_read == 0 {
                break;
            }
            for task in &self.tasks {
                task.process_chunk(&buffer[..bytes_read])?;
            }
        }
        Ok(())
    }
}


4.4. Thread Safety in Rust

Rust’s ownership model and type system help ensure thread safety. The Send and Sync traits are crucial for concurrent programming:

pub trait ThreadSafeTask: Task + Send + Sync {}

impl<T: Task + Send + Sync> ThreadSafeTask for T {}


4.5. Parquet Writer Implementation

We implement a custom Parquet writer that leverages Rust’s type system:

pub trait ParquetRecordWriter {
fn write_record<W: Write>(&self, writer: &mut ParquetWriter<W>) -> Result<(), Box<dyn Error>>;
}

pub struct ParquetWriter<W: Write> {
writer: SerializedFileWriter<W>,
}

impl<W: Write> ParquetWriter<W> {
pub fn new(writer: W, schema: SchemaDescriptor) -> Result<Self, Box<dyn Error>> {
let props = WriterProperties::builder().build();
let file_writer = SerializedFileWriter::new(writer, schema, Arc::new(props))?;
Ok(ParquetWriter { writer: file_writer })
}

    pub fn write<T: ParquetRecordWriter>(&mut self, record: &T) -> Result<(), Box<dyn Error>> {
        record.write_record(self)
    }

    pub fn close(self) -> Result<(), Box<dyn Error>> {
        self.writer.close()?;
        Ok(())
    }
}


5. AWS Integration

5.1. S3 Upload Process

We use the rusoto_s3 crate to handle S3 uploads:

use rusoto_core::Region;
use rusoto_s3::{PutObjectRequest, S3Client, S3};
use tokio::fs::File;
use tokio::io::AsyncReadExt;

async fn upload_to_s3(
bucket: &str,
key: &str,
file_path: &str,
) -> Result<(), Box<dyn Error>> {
let client = S3Client::new(Region::UsEast1);
let mut file = File::open(file_path).await?;
let mut contents = Vec::new();
file.read_to_end(&mut contents).await?;

    let req = PutObjectRequest {
        bucket: bucket.to_string(),
        key: key.to_string(),
        body: Some(contents.into()),
        ..Default::default()
    };

    client.put_object(req).await?;
    Ok(())
}


5.2. AWS Glue Crawler

After uploading the Parquet files to S3, we use an AWS Glue Crawler to create and update the schema in the Glue Data Catalog. This process is typically managed through AWS CloudFormation or Terraform:

Resources:
GlueCrawler:
Type: AWS::Glue::Crawler
Properties:
Name: ParquetDataCrawler
Role: !Ref GlueCrawlerRole
DatabaseName: !Ref GlueDatabase
Targets:
S3Targets:
- Path: !Sub "s3://${S3Bucket}/parquet-data/"
Schedule:
ScheduleExpression: cron(0 1 * * ? *)


6. Executing the ETL Program

Our ETL program is typically executed as a Kubernetes job. Here’s a simplified example of how we might define this job:

apiVersion: batch/v1
kind: Job
metadata:
name: etl-job
spec:
template:
spec:
containers:
- name: etl-container
image: our-etl-image:latest
env:
- name: POSTGRES_URL
valueFrom:
secretKeyRef:
name: db-secrets
key: postgres-url
- name: AWS_ACCESS_KEY_ID
valueFrom:
secretKeyRef:
name: aws-secrets
key: access-key-id
- name: AWS_SECRET_ACCESS_KEY
valueFrom:
secretKeyRef:
name: aws-secrets
key: secret-access-key
restartPolicy: Never


7. Retrospective and Lessons Learned





Version Lock-in: We couldn’t upgrade our Rust version due to dependency conflicts, limiting access to new language features. This taught us the importance of regularly updating dependencies and considering long-term maintainability.



Complexity Trade-off: While we gained type safety, we introduced complexity in our build process and dependency management. This highlighted the need for comprehensive documentation and onboarding processes.



Performance Wins: The Rust-based ETL significantly outperforms our previous solutions in terms of speed and resource usage. This validated our choice of Rust for performance-critical operations.



Maintenance Challenges: As the codebase grew, we faced difficulties in onboarding new team members to the Rust ecosystem. We’ve since implemented pair programming and code review practices to mitigate this.



Type Safety Benefits: The strong type system caught numerous potential bugs at compile-time, significantly reducing runtime errors in production.



Ecosystem Limitations: While Rust’s ecosystem is growing, we sometimes found ourselves reimplementing functionality that would have been readily available in more mature data processing ecosystems like Python’s.



Deployment Complexity: Deploying Rust applications in a Kubernetes environment required some additional work compared to more commonly used languages in this space.



Testing Strategies: We developed comprehensive testing strategies, including unit tests, integration tests, and property-based testing using the proptest crate.

8. Conclusion

Our Rust-based ETL pipeline has successfully addressed our initial challenges of security, performance, and operational complexity. By moving ETL workloads to this custom pipeline, we’ve optimized costs and kept our Postgres instance focused on its core transactional role.

While the journey has had its challenges, the benefits of type safety, performance, and flexibility have made it worthwhile. For teams facing similar ETL challenges, our approach offers a blueprint for leveraging modern tools like Rust, S3, and Athena to build efficient, secure data pipelines.

The key takeaways from our experience are:





Prioritize type safety and compile-time checks for data-intensive applications.



Consider the trade-offs between using cutting-edge technologies and long-term maintainability.



Invest in team training and documentation when adopting less mainstream technologies.



Leverage cloud-native solutions (like S3 and Athena) to build scalable data pipelines.



Regularly review and update dependencies to avoid version lock-in.



Implement comprehensive testing strategies to ensure reliability.



Be prepared to invest time in building custom solutions when working with newer ecosystems.

As we continue to evolve our data infrastructure, we remain committed to exploring innovative solutions that balance performance, security, and maintainability. Our experience with Rust in ETL has opened up new possibilities for high-performance data processing, and we’re excited to see how this approach can be applied to other areas of our data infrastructure.