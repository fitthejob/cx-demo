# PRD Index

This directory contains the public product requirements and architecture documents for the platform.

The files are grouped here in intended review order so readers do not have to rely on GitHub's default filename sorting.

## Foundation

- [PRD-00 - Terraform State and Backend Bootstrap](./PRD-00-v1.2.0-terraform-state-backend-bootstrap.md)
- [PRD-01 - GitHub Actions CI/CD Pipeline](./PRD-01-v1.1.0-github-actions-cicd-pipeline.md)
- [PRD-02 - AWS Account Baseline](./PRD-02-v1.1.0-aws-account-baseline.md)
- [PRD-03 - Audit Evidence Collection Pipeline](./PRD-03-v1.2.0-audit-evidence-collection-pipeline.md)

## Core Telephony

- [PRD-10 - Amazon Connect Instance Configuration](./PRD-10-v1.0.0-amazon-connect-instance-configuration.md)
- [PRD-10a - Voicemail Solution, Mailboxes, and Routing](./PRD-10a-v1.0.0-voicemail-solution-mailboxes-routing.md)
- [PRD-11 - Phone Number Management and DID Provisioning](./PRD-11-v1.1.0-phone-number-management-did-provisioning.md)
- [PRD-12 - Hours of Operation and Holiday Schedules](./PRD-12-v1.0.0-hours-of-operation-holiday-schedules.md)
- [PRD-13 - Queue Architecture and Routing Profiles](./PRD-13-v1.1.0-queue-architecture-routing-profiles.md)
- [PRD-14 - Base Contact Flow Framework](./PRD-14-v1.0.0-base-contact-flow-framework.md)

## Number Governance And Compliance

- [PRD-15 - Number Portability Verification](./PRD-15-v1.0.0-number-portability-verification.md)
- [PRD-16 - Spam Reputation and STIR/SHAKEN](./PRD-16-v1.0.0-spam-reputation-stir-shaken.md)
- [PRD-17 - CNAM Registry Management](./PRD-17-v1.0.0-cnam-registry-management.md)
- [PRD-18 - E911 Emergency Services Compliance](./PRD-18-v1.0.0-e911-emergency-services-compliance.md)
- [PRD-19 - Routing Drift Detection](./PRD-19-v1.0.0-routing-drift-detection.md)

## Eventing And Audit Extensions

- [PRD-20 - EventBridge Custom Bus and Schema Registry](./PRD-20-v1.0.0-eventbridge-custom-bus-schema-registry.md)
- [PRD-21 - Dead Letter Queue and Poison Message Handling](./PRD-21-v1.0.0-dead-letter-queue-poison-message-handling.md)
- [PRD-22 - Event Replay and Audit Log Service](./PRD-22-v1.0.0-event-replay-audit-log-service.md)

## Storage And Data Architecture

- [PRD-30 - S3 Architecture for Recordings and Voicemail Artifacts](./PRD-30-v1.0.0-s3-architecture-recordings-voicemail-artifacts.md)
- [PRD-31 - DynamoDB Table Design for Contact and Agent State](./PRD-31-v1.0.0-dynamodb-table-design-contact-state-agent-state.md)
- [PRD-32 - Data Retention and Lifecycle Policy Service](./PRD-32-v1.0.0-data-retention-lifecycle-policy-service.md)

## Lambda Platform

- [PRD-40 - Lambda Baseline, Layers, Powertools, and Error Handling](./PRD-40-v1.0.0-lambda-baseline-layers-powertools-error-handling.md)
- [PRD-41 - Lambda Deployment Pipeline and Versioning Strategy](./PRD-41-v1.0.0-lambda-deployment-pipeline-versioning-strategy.md)

## Agent Experience

- [PRD-50 - Agent Hierarchy and User Management](./PRD-50-v1.0.0-agent-hierarchy-user-management.md)
- [PRD-51 - Contact Control Panel Configuration](./PRD-51-v1.0.0-contact-control-panel-ccp-configuration.md)
- [PRD-52 - Whisper Flow Service](./PRD-52-v1.0.0-whisper-flow-service.md)
- [PRD-53 - Agent-to-Agent Transfer Service](./PRD-53-v1.0.0-agent-to-agent-transfer-service.md)
- [PRD-54 - Routing Profile Management](./PRD-54-v1.0.0-routing-profile-management.md)

## Voicemail Services

- [PRD-60 - Voicemail Recording Storage Service](./PRD-60-v1.0.0-voicemail-recording-storage-service.md)
- [PRD-61 - Voicemail Transcription Service](./PRD-61-v1.0.0-voicemail-transcription-service.md)
- [PRD-62 - Voicemail-to-Email Notification Service](./PRD-62-v1.0.0-voicemail-to-email-notification-service.md)

## Conversational Routing

- [PRD-70 - Lex V2 Bot Foundation and Versioning](./PRD-70-v1.0.0-lex-v2-bot-foundation-versioning.md)
- [PRD-71 - Intent Design and Slot Architecture](./PRD-71-v1.0.0-intent-design-slot-architecture.md)
- [PRD-72 - Connect and Lex Integration Layer](./PRD-72-v1.0.0-connect-lex-integration-layer.md)
- [PRD-73 - Bot Fallback and Escalation Handler](./PRD-73-v1.0.0-bot-fallback-escalation-handler.md)

## Observability

- [PRD-80 - CloudWatch Dashboard Metrics Framework](./PRD-80-v1.0.0-cloudwatch-dashboard-metrics-framework.md)
- [PRD-81 through PRD-83 - Observability, Alerting, Contact Lens, and FinOps](./PRD-81-82-83-v1.0.0-observability-alerting-contact-lens-finops.md)

## Migration

- [PRD-90 - Migration State](./PRD-90-v1.0.0-migration-state.md)
- [PRD-91 - Cutover Operations](./PRD-91-v1.0.0-cutover-operations.md)

## Future Layer Bundles

- [PRD-100 through PRD-104 - Scale and Resilience Layer](./PRD-100-104-v1.0.0-scale-resilience-layer.md)
- [PRD-110 through PRD-115 - Multi-Account Topology Layer](./PRD-110-115-v1.0.0-multi-account-topology-layer.md)
- [PRD-120 through PRD-123 - Optional AD and SSO Integration Layer](./PRD-120-123-v1.0.0-optional-ad-sso-integration-layer.md)
- [PRD-130 through PRD-133 - Optional CRM Integration Layer](./PRD-130-133-v1.0.0-optional-crm-integration-layer.md)
- [PRD-140 through PRD-142 - Optional Compliance Hardening Layer](./PRD-140-142-v1.0.0-optional-compliance-hardening-layer-FINAL.md)

## Governance References

- [PRD Modularity Readiness Checklist](./PRD-MODULARITY-READINESS-CHECKLIST.md)
- [PRD Template Modularity Section](./PRD-TEMPLATE-MODULARITY-SECTION.md)
