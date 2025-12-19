---
layout: post
title: "Building TransformDash: A Lightweight Alternative to dbt"
date: 2025-11-18
img: chart.avif
categories: [data-engineering, open-source]
---

I've been working on a side project for the past few months that I finally got around to cleaning up and open-sourcing. It's called TransformDash, and it's basically my attempt at answering the question: "What if I want dbt-style transformations but don't want to set up a whole data warehouse?"

## The Problem

I kept running into the same situation at work and on side projects. I'd have data in PostgreSQL or MongoDB, and I wanted to write clean, modular SQL transformations like you do in dbt. But dbt really wants you to have Snowflake or BigQuery or at least a dedicated analytics database.

Sometimes you just have a Postgres instance and want to transform data there. Or you're prototyping and don't want to spin up infrastructure. Or you're working with smaller datasets where a full warehouse is overkill.

## What I Built

TransformDash lets you write SQL models in the dbt style - with `{{ source() }}` and `{{ ref() }}` macros, Jinja templating, and dependency resolution. But it runs directly against your existing databases.

The interesting parts:

**DAG Resolution**: Built a dependency resolver that figures out model execution order. If you have `gold_users` that depends on `silver_users` that depends on `stg_users`, it runs them in the right order automatically.

**Multiple Materializations**: Models can be views or tables, each with different performance tradeoffs. You can also write models with incremental syntax (`{% raw %}{% if is_incremental() %}{% endraw %}`), but right now they do full refreshes. True incremental support - where the system tracks table state and does INSERT-only updates instead of DROP/CREATE - is on the roadmap.

**Built-in Viz**: Since I was already building the execution layer, I threw in a dashboard system. It's nothing fancy - Chart.js on the frontend - but it's handy for quick data checks.

## Tech Stack

Backend is FastAPI because it's fast to work with and the async support is nice for running multiple queries in parallel. Frontend is vanilla JavaScript - no framework bloat. I probably should have used React or Vue but honestly, for this use case, vanilla JS was fine and I didn't want to deal with build tooling.

Authentication uses JWT with bcrypt for password hashing. I spent more time than I'd like to admit making sure the SQL construction was safe - everything uses parameterized queries and psycopg2's sql composition tools to avoid injection attacks.

The deployment story is pretty straightforward: Docker Compose for local development, Kubernetes manifests for production. I tried to make it runnable with minimal configuration.

## Things I Learned

**SQL Composition is Hard**: Building SQL queries programmatically while keeping them safe from injection is tricky. Python's string formatting wants to make it easy to shoot yourself in the foot. I ended up using psycopg2.sql everywhere and writing validation for every identifier.

**Incremental Logic is Subtle**: dbt makes incremental models look simple, but there's a lot of edge case handling. What happens if the source table changes schema? What if someone drops the incremental table? I have the syntax working (you can write `{% raw %}{% if is_incremental() %}{% endraw %}`), but right now it just does full refreshes. Implementing true incremental support - tracking state, detecting changes, doing INSERT instead of DROP/CREATE - is on my todo list.

**Documentation Takes Forever**: I thought coding was the hard part. Turns out writing docs that actually help people get started is way harder. I went through three rewrites of the README before it made sense.

## Current State

It works. I've been using it on a few projects and it does what I need. That said, there are rough edges:

- The UI could use design work (it's functional but ugly)
- Error messages aren't always helpful
- No built-in testing framework yet
- Performance could be better for large datasets

But for small to medium datasets and quick iterations, it's pretty useful.

## Try It Out

**Live Demo**: [https://transformdash-demo.onrender.com](https://transformdash-demo.onrender.com) (login: demo/demo)

The demo runs on Render's free tier and includes sample e-commerce data (100 customers, 500 orders). You can run transformations, build dashboards, and explore the lineage visualization. First load takes 30-60 seconds if the server is sleeping.

**Install from PyPI**:

```bash
pip install transformdash
```

**Or run from source**:

```bash
git clone https://github.com/kraftaa/transformdash.git
cd transformdash
docker-compose up -d
```

GitHub: [https://github.com/kraftaa/transformdash](https://github.com/kraftaa/transformdash)

## Deploying Your Own Demo

Hosting a demo on Render's free tier is straightforward. Add a `render.yaml`:

```yaml
services:
  - type: web
    name: transformdash-demo
    env: docker
    plan: free

databases:
  - name: transformdash-db
    plan: free
```

Connect your GitHub repo, and Render handles the rest. The free tier includes:
- PostgreSQL database (90 days, renewable)
- Web service (sleeps after 15 min, wakes in 30 sec)
- Auto-deployment on git push

The entrypoint script automatically seeds sample data, creates read-only protections for source tables, and sets up demo credentials. Perfect for letting people try your data platform before installing.

## What's Next

I'm planning to add:

- True incremental model support (tracking state, INSERT-only updates)
- A testing framework for model validation
- Support for more databases (ClickHouse would be interesting)
- Some kind of scheduling system

I'm primarily building this for my own use cases, but I want it to be genuinely useful for others. If you try it and have feature requests, let me know - I'd be happy to prioritize things that help real users.

If you end up trying it, let me know how it goes. And if you find bugs (you will), issues and PRs are welcome.

---

Check out my other projects at [github.com/kraftaa](https://github.com/kraftaa)
