# Architecture & Diagrams

Rendered inline by GitHub (Mermaid). Each diagram is the source of truth for one view.

## 1. Full stack

```mermaid
flowchart TB
    subgraph SRC["Source"]
        LMS["PostgreSQL (LMS)<br/>loan / loan_event"]
        API["LMS API (FastAPI)"]
    end

    subgraph CDC["Change Data Capture"]
        DBZ["Debezium"] --> KAFKA["Kafka (KRaft)"]
    end

    subgraph LK["Lakehouse"]
        KAFKA --> SINK["Iceberg sink"]
        SINK --> MINIO[("MinIO<br/>object store")]
        POLARIS[("Polaris<br/>catalog")]
    end

    subgraph TR["Transform (dbt)"]
        BRZ["Bronze"] --> SLV["Silver"] --> GLD["Gold"]
        SLV -. "failing rows" .-> Q[("quarantine_lms")]
    end

    subgraph SRV["Serve"]
        GLD --> TRINO["Trino"] --> MB["Metabase (BI)"]
    end

    subgraph OBS["Observability + Incidents"]
        PROM["Prometheus"] --> GRAF["Grafana"]
        PROM --> AM["Alertmanager"] --> BRIDGE["ticket-bridge"] --> PLANE["Plane"]
    end

    API --> DBZ
    DEMO["Demo control panel :8001"] --> API
    DEMO -. "scenario" .-> PLANE
```

## 2. Data flow — medallion + quarantine

```mermaid
flowchart LR
    CDC["CDC events"] --> BRZ["Bronze<br/>raw append-only"]
    BRZ --> SLV["Silver<br/>dedupe + cast + tests"]
    SLV -->|"tests pass"| GLD["Gold<br/>marts"]
    SLV -->|"tests fail"| Q[("quarantine_lms<br/>rule + timestamp")]
    GLD --> BI["Metabase<br/>KPIs"]
    Q --> DQ["Data Quality<br/>panel"]
```

Key property: bad data never reaches a KPI — it lands in `quarantine_lms` and is shown
in the Data Quality panel, traceable to its failing test.

## 3. Network — prod posture (public / private)

```mermaid
flowchart LR
    INET["Internet"] --> LB["External HTTPS LB<br/>TLS + Cloud Armor"]
    subgraph VPC["VPC"]
        subgraph PUB["public-subnet"]
            NAT["Cloud NAT"]
            TRAEFIK["Traefik<br/>reverse proxy"]
        end
        subgraph PRIV["private-subnet"]
            VM["App VM<br/>full stack"]
        end
        LB --> TRAEFIK --> VM
        VM -. "outbound" .-> NAT
    end
```

Public (via LB + Traefik + IAP/auth + TLS): `grafana.<domain>`, `demo.<domain>`
(control panel), `bi.<domain>`, `plane.<domain>`. Everything else — Postgres, Kafka,
MinIO, Polaris, Trino, dbt, Prometheus, Alertmanager — is private-only. SSH via IAP,
never `0.0.0.0/0`.
