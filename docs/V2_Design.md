# V2 Design: Event-Driven Reliability with AWS-Managed Services

## Why V2 exists

V1 of the Kubernetes Incident Response Platform delivered the headline feature: an alert fires in Prometheus, our incident-service gathers context, calls Claude, and posts a structured analysis to Slack within seconds. The pipeline works.

The professor's feedback after our class demo highlighted a real architectural gap: V1 leans on in-cluster, self-hosted components for the entire pipeline. That choice was intentional — it kept the system transparent and portable — but it also concentrates risk. If any single in-cluster component crashes between alert firing and Slack post, the alert can be lost silently.

V2 keeps V1's core architecture and adds three AWS-managed services that turn the pipeline event-driven and meaningfully more reliable. The goal is not 100% reliability — no monitoring system can claim that honestly — but to close the most likely failure modes while keeping the system understandable.

## What V2 adds

Three new components, each addressing a specific class of failure.

**Amazon SQS** sits between Alertmanager and the incident-service. In V1, Alertmanager POSTs the alert directly to the service over HTTP. If the service crashes between accepting the request and finishing the Claude call, the alert is gone — Alertmanager already received its 200 OK and will not retry. In V2, a small new component called `sqs-publisher` receives the HTTP webhook from Alertmanager and immediately enqueues the alert in SQS. The incident-service then consumes from the queue on its own schedule. If it crashes mid-processing, the message becomes visible again after the visibility timeout and gets reprocessed.

**Amazon SNS** sits between the incident-service and its notification destinations. V1 publishes directly to a single Slack webhook. If Slack is rate-limiting, has revoked the webhook, or is having a regional incident, the notification is lost. V2 publishes to an SNS topic that fans out to multiple subscribers — Slack as the primary, but also an email address as a parallel path. If one subscriber fails, the others still deliver.

**Amazon CloudWatch Synthetics** runs entirely outside the cluster. A scheduled canary hits the application services from the public internet every minute. If the check fails repeatedly, a CloudWatch Alarm fires and is routed to the same SNS topic. This is a redundant monitoring path that does not depend on Prometheus, Alertmanager, or any in-cluster component. It catches the scenario where the whole in-cluster monitoring stack is broken and the operator would otherwise have no idea.

## Architecture

```
                                       V2 Architecture
                                       ───────────────

   Application services (payment / order / load-generator) emit metrics and logs
                                            │
                                            ▼
                                       Prometheus
                                            │
                                  alert rule evaluates
                                            │
                                            ▼
                                      Alertmanager
                                            │
                                  HTTP POST /webhook/alert
                                            │
                                            ▼
                                     sqs-publisher       ◄── IRSA (write to SQS)
                                            │
                                            ▼
                                  ┌────────────────┐
                                  │   SQS queue    │
                                  └────────────────┘
                                            │
                                  poll & receive (long poll)
                                            │
                                            ▼
                                   incident-service       ◄── IRSA (read SQS, publish SNS)
                                            │
                              ┌─────────────┼─────────────┐
                              ▼             ▼             ▼
                         Prometheus       Loki      Kubernetes API
                         (metrics)       (logs)       (env, events)
                              └─────────────┼─────────────┘
                                            ▼
                                       Claude API
                                            │
                                            ▼
                                       SNS topic
                                       ╱     ╲
                                  Slack       Email subscriber
                                  webhook     (independent path)


                                  Parallel monitoring path
                                  ───────────────────────

                          ┌─────────────────────────────────┐
                          │ CloudWatch Synthetics (canary)  │
                          │ runs outside cluster, every 1m  │
                          └────────────────┬────────────────┘
                                           │
                              HTTP check against /health endpoints
                                           │
                                           ▼
                                  CloudWatch Alarm
                                           │
                                           ▼
                                      SNS topic
                                       ╱     ╲
                                  Slack       Email
```

## Failure mode coverage

The table below lists each component failure, what V1 did about it, and what V2 changes. The honest answer is that V2 closes some gaps and explicitly does not close others.

| Failure scenario | V1 behavior | V2 behavior | Notes |
|---|---|---|---|
| Application service crashes (e.g. payment-service) | Detected, alert fires | Same | Synthetics adds a second detection path |
| incident-service crashes mid-processing | Alert lost; Alertmanager already got 200 OK | Alert persists in SQS; reprocessed when service recovers | **Biggest reliability win in V2** |
| Slack webhook rate-limited or revoked | Notification lost | Email subscriber on SNS still delivers | SNS provides notification redundancy |
| Prometheus pod crashes | No metrics during downtime; in-flight alerts lost | Same | Synthetics still detects app failures externally |
| Alertmanager pod crashes | In-flight alerts lost | Same | Synthetics still detects via independent path |
| Grafana pod crashes | Dashboards unavailable; no impact on alerting | Same | Not on the critical path |
| Entire in-cluster monitoring down | Total blindness | Synthetics still detects app failures | Independent monitoring path is the entire point |
| Cluster region down | Total blindness | Total blindness | Multi-region was considered, see "Deferred" |

The pattern is clear. SQS addresses the "service crashes mid-flow" class of failure. SNS addresses the "single notification target fails" class. Synthetics addresses the "in-cluster monitoring itself is broken" class. Each is a meaningful improvement; none claims to make the system bulletproof.

## What V2 deliberately does not include

These were considered and rejected for this iteration, with stated reasons.

**Multi-region deployment.** A regional AWS outage takes down the cluster regardless of in-cluster reliability. Multi-region with active-active EKS clusters, Route 53 health-checked failover, and cross-region SQS replication would address this. It also roughly doubles cost and significantly increases operational complexity. For a portfolio project, the value of demonstrating the pattern does not justify the spend.

**Amazon Managed Service for Prometheus (AMP).** Replacing self-hosted Prometheus with AMP would make Prometheus itself a non-issue — AWS handles HA, multi-AZ, storage retention. We kept self-hosted Prometheus because it remains the transparent piece of the project; we can show the alert rules, the query language, the scrape configuration. Migrating to AMP would be a sensible next iteration once the platform is stable.

**Amazon Bedrock for Claude.** Currently the incident-service calls Anthropic's API directly. Bedrock would host Claude inside AWS with its own retry and SLA. The trade-off is cost (Bedrock pricing differs) and the fact that direct Anthropic access has worked reliably during V1 testing. Worth revisiting if rate-limiting becomes an issue.

**HA Prometheus and Alertmanager (multiple replicas).** Running two replicas of each with deduplication at the Alertmanager layer would close the "Prometheus/Alertmanager crash" gap that Synthetics only partially mitigates. This is the right next step after V2. Deferred because Synthetics provides 80% of the value at 20% of the operational complexity.

**Dead-letter queue on SQS.** A DLQ would catch messages that fail to process repeatedly, preventing them from blocking the main queue. Recommended for production but deferred from V2 to keep the implementation focused. Easy to add later.

## Implementation plan

Four sessions, roughly 6 to 8 hours total.

**Session 1 — SQS integration.** Add SQS queue and IAM resources to Terraform. Build the new `sqs-publisher` service (small FastAPI app that receives Alertmanager webhooks and enqueues to SQS). Refactor incident-service from HTTP receiver to SQS consumer. Wire IRSA so both services can authenticate to SQS without baked-in AWS credentials. Test by killing incident-service mid-processing and verifying the alert is reprocessed when the pod restarts.

**Session 2 — SNS notification fanout.** Add SNS topic to Terraform. Subscribe the Slack webhook and an email address. Modify incident-service to publish analysis results to SNS instead of POSTing directly to Slack. Test by temporarily revoking the Slack webhook and verifying the email subscriber still receives the alert.

**Session 3 — CloudWatch Synthetics canary.** Add Synthetics canary to Terraform with a Node.js or Python script that hits the order-service `/health` endpoint every minute. Configure a CloudWatch Alarm that fires after three consecutive failures. Route the alarm to the SNS topic from Session 2. Test by scaling order-service to zero and verifying the canary alarm fires and reaches Slack via SNS.

**Session 4 — Documentation and demo.** Update the project README with the V2 architecture diagram, link to this design document, record a 90-second demo video that shows one of the new failure scenarios (most likely: kill incident-service mid-processing, watch SQS hold the alert, restart the service, watch processing resume). Send a follow-up email to the professor with the GitHub link and a summary of what changed.

## Costs

All three additions stay well within hobbyist tier limits and add roughly $10 to $15 per month to the existing $20 V1 spend.

SQS: less than $1 per month at this scale (millions of free tier requests, our usage will be dozens).

SNS: free for the first million publishes and notifications per month; we will not approach this.

CloudWatch Synthetics: roughly $1.50 per canary per month at 1-minute frequency. One canary suffices.

Anthropic Claude API: unchanged from V1, roughly $0.01 per analysis.

The platform retains the destroy-nightly discipline established in V1, so most of these costs are pro-rated against actual usage hours.

## What this proves about the architecture

V2 demonstrates three things that V1 alone could not.

First, event-driven design. Decoupling the alert ingestion path (Alertmanager → publisher → queue) from the processing path (consumer → Claude → notification) means each can fail or scale independently. This is the core of how production systems handle bursty, unreliable input.

Second, intentional reliability tradeoffs. Each AWS service was added to close a specific failure mode, and the design document explicitly states what is still not addressed. This is more honest and more useful than the alternative "we added every AWS service we could think of."

Third, AWS-managed services as a reliability layer over self-hosted components. The cluster still runs Prometheus, Loki, ArgoCD, and the application services — that is the transparent, portable core. AWS-managed services wrap that core in durability (SQS), redundancy (SNS), and external observability (Synthetics). This pattern — keep the core open-source, add managed services at the edges — is how many real production teams structure their stack.

## Open questions for the professor

A few specific questions where the professor's guidance would shape the next iteration.

Would Bedrock-hosted Claude be a stronger story than direct Anthropic API, given the architecture's AWS focus? It adds cost and a small amount of code complexity, but keeps the entire pipeline within AWS for governance and audit purposes.

Is there value in adding AMP (Managed Prometheus) and AMG (Managed Grafana) as a fifth session, accepting the cost increase, or is the self-hosted approach more pedagogically valuable for a portfolio project?

Would a multi-region demo — even if just a sketched-out Terraform module rather than a fully running second cluster — strengthen the architecture story without doubling the running cost?

These are not blockers for V2 as scoped above. They are directions V3 could take if the project continues to evolve.