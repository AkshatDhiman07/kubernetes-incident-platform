# Kubernetes Incident Response Platform

AI-augmented incident detection and root-cause analysis for Kubernetes on AWS.

## Overview

A platform that watches a running EKS cluster, detects production incidents
via Prometheus + Alertmanager, gathers context from logs and recent deploys,
and uses the OpenAI API to generate human-readable root cause analyses
delivered to Slack.

## Architecture

[Architecture diagram will go here]

## Tech Stack

- **Cloud:** AWS (EKS, RDS, ECR, Secrets Manager)
- **IaC:** Terraform
- **GitOps:** ArgoCD
- **Observability:** Prometheus, Grafana, Loki, Alertmanager
- **AI:** OpenAI API (GPT-4)
- **Languages:** Python (FastAPI), HCL, YAML

## Project Status

In active development — see [NOTES.md](./NOTES.md) for weekly progress.

## Setup

Coming as the project develops.

## Demo

3-minute demo video link will go here.

## Roadmap

- [x] Week 1: AWS + EKS foundation
- [ ] Week 2: ArgoCD + GitOps setup
- [ ] Week 3-4: Observability stack
- [ ] Week 5-6: Incident response service
- [ ] Week 7: Polish + demo
- [ ] Week 8: Buffer + AWS SAA exam

## Author

Akshat Dhiman, Maharshi Patel — MPS Informatics, Northeastern University
